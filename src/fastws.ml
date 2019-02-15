(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Sexplib.Std

open Httpaf

module type CRYPTO = sig
  type buffer
  type g
  val generate: ?g:g -> int -> buffer
  val sha_1 : buffer -> buffer
  val of_string: string -> buffer
  val to_string: buffer -> string
end

module Crypto = struct
  type buffer = string
  type g = Random.State.t

  let to_string t = t
  let of_string t = t

  let generate ?(g=Random.get_state ()) len =
    Bytes.init len (fun _ -> Char.chr (Random.State.bits g land 0xFF)) |>
    Bytes.unsafe_to_string

  include Sha1
end

let websocket_uuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

let headers ?protocols nonce =
  Headers.of_list @@
  ("Upgrade", "websocket") ::
  ("Connection", "Upgrade") ::
  ("Sec-WebSocket-Key", nonce) ::
  match protocols with
  | None -> ["Sec-WebSocket-Version", "13"]
  | Some ps ->
    ("Sec-WebSocket-Version", String.concat ", " ps) ::
    ["Sec-WebSocket-Version", "13"]

module Status = struct
  type t =
    | NormalClosure
    | GoingAway
    | ProtocolError
    | UnsupportedDataType
    | InconsistentData
    | ViolatesPolicy
    | MessageTooBig
    | UnsupportedExtension
    | UnexpectedCondition
    | Unknown of int

  let of_int = function
    | 1000 -> NormalClosure
    | 1001 -> GoingAway
    | 1002 -> ProtocolError
    | 1003 -> UnsupportedDataType
    | 1007 -> InconsistentData
    | 1008 -> ViolatesPolicy
    | 1009 -> MessageTooBig
    | 1010 -> UnsupportedExtension
    | 1011 -> UnexpectedCondition
    | status -> Unknown status

  let to_int = function
    | NormalClosure        -> 1000
    | GoingAway            -> 1001
    | ProtocolError        -> 1002
    | UnsupportedDataType  -> 1003
    | InconsistentData     -> 1007
    | ViolatesPolicy       -> 1008
    | MessageTooBig        -> 1009
    | UnsupportedExtension -> 1010
    | UnexpectedCondition  -> 1011
    | Unknown status       -> status
end

module Opcode = struct
  type t =
    | Continuation
    | Text
    | Binary
    | Close
    | Ping
    | Pong
    | Ctrl of int
    | Nonctrl of int
  [@@deriving sexp]

  let compare = Pervasives.compare
  let equal = Pervasives.(=)

  let pp ppf t =
    Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

  let of_int = function
    | i when (i < 0 || i > 0xf) -> invalid_arg "Opcode.of_int"
    | 0                         -> Continuation
    | 1                         -> Text
    | 2                         -> Binary
    | 8                         -> Close
    | 9                         -> Ping
    | 10                        -> Pong
    | i when i < 8              -> Nonctrl i
    | i                         -> Ctrl i

  let to_int = function
    | Continuation   -> 0
    | Text           -> 1
    | Binary         -> 2
    | Close          -> 8
    | Ping           -> 9
    | Pong           -> 10
    | Ctrl i         -> i
    | Nonctrl i      -> i
end

type t = {
  opcode : Opcode.t ;
  rsv : int ;
  final : bool ;
  content: string ;
} [@@deriving sexp]

let compare = Pervasives.compare
let equal = Pervasives.(=)

let pp ppf t =
  Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

let show t = Format.asprintf "%a" pp t

let create ?(rsv=0) ?(final=true) ?(content="") opcode =
  { opcode ; rsv ; final ; content }

let ping = create Opcode.Ping
let pong = create Opcode.Pong

let pingf fmt =
  Format.kasprintf (fun content -> create ~content Opcode.Ping) fmt
let pongf fmt =
  Format.kasprintf (fun content -> create ~content Opcode.Pong) fmt

let close ?msg () =
  match msg with
  | None -> create Opcode.Close
  | Some (status, msg) ->
    let msglen = String.length msg in
    let content = Bytes.create (2 + msglen) in
    EndianBytes.BigEndian.set_int16 content 0 (Status.to_int status) ;
    Bytes.blit_string msg 0 content 2 msglen ;
    let content = Bytes.unsafe_to_string content in
    create ~content Opcode.Close

let closef status =
  Format.kasprintf (fun msg -> close ~msg:(status, msg) ())

type pos =
  | Hdr1
  | Hdr2
  | Len of int
  | Mask of int
  | Data of int
  | EOF

type state = {
  pos : pos ;
  mask : bytes option ;
  len : int ;
}

let get_finmask c = Char.code c land 0x80 <> 0
let get_rsv c = (Char.code c lsr 4) land 0x7
let get_len c = Char.code c land 0x7f
let get_opcode c = Opcode.of_int (Char.code c land 0xf)

let xor_char a b =
  Char.(chr (code a lxor code b))

let xormask ~mask buf =
  Bytes.iteri begin fun i c ->
    Bytes.set buf i (xor_char c (String.get mask (i mod 4)))
  end buf

let parser =
  let open Angstrom in
  let init = {
    pos = Hdr1 ;
    mask = None ;
    len = 0 ;
  } in
  scan (init, create Opcode.Continuation) begin fun (state, frame) c ->
    match state.pos with
    | EOF -> None
    | Hdr1 ->
      let final = get_finmask c in
      let rsv = get_rsv c in
      let opcode = get_opcode c in
      Some ({ state with pos = Hdr2 }, create ~rsv ~final opcode)
    | Hdr2 ->
      begin
        match get_len c, get_finmask c with
        | 126, false -> Some ({ state with pos = Len 1 }, frame)
        | 127, false -> Some ({ state with pos = Len 7 }, frame)
        | 126, true -> Some ({ state with pos = Len 1 ;
                                          mask = Some (Bytes.create 4)}, frame)
        | 127, true -> Some ({ state with pos = Len 7 ;
                                          mask = Some (Bytes.create 4)}, frame)
        | n, false -> begin
            match n with
            | 0   -> Some ({ state with pos = EOF }, frame)
            | len -> Some ({ state with pos = Data (pred len) ; len }, frame)
          end
        | n, true ->
          Some ({ pos = Mask 3 ;
                  mask = Some (Bytes.create 4) ;
                  len = n }, frame)
      end
    | Len 0 -> begin
        let len = state.len lor Char.code c in
        match state.mask with
        | Some _ -> Some ({ state with pos = Mask 3 ; len }, frame)
        | None   -> Some ({ state with pos = Data (pred len) ; len }, frame)
      end
    | Len n ->
      let len =
        state.len lor ((Char.code c) lsl (8*n)) in
      Some ({ state with pos = Len (pred n) ; len }, frame)
    | Mask n -> begin
        match state.mask with
        | None -> assert false
        | Some buf ->
          Bytes.set buf (3 - n) c ;
          begin match n, state.len = 0 with
            | 0, true -> Some ({ state with pos = EOF }, frame)
            | 0, false ->
              Some ({ state with pos = Data (pred state.len) }, frame)
            | _ ->
              Some ({ state with pos = Mask (pred n) }, frame)
          end
      end
    | Data 0 ->
      Some ({ state with pos = EOF }, frame)
    | Data n ->
      Some ({ state with pos = Data (pred n) }, frame)
  end |>
  lift begin fun (content, (st, frame)) ->
    if String.length content < 2 then None
    else
      let skip = if st.len < 126 then 2
        else if st.len < 1 lsl 16 then 4
        else 10 in
      match st.mask with
      | None ->
        Some { frame with content = String.sub content skip st.len }
      | Some mask ->
        let content = String.sub content (skip + 4) st.len in
        let buf = Bytes.unsafe_of_string content in
        xormask ~mask:(Bytes.unsafe_to_string mask) buf ;
        Some { frame with content = Bytes.unsafe_to_string buf }
  end

let parser_exn =
  Angstrom.lift
    (function None -> failwith "parser_exn" | Some v -> v) parser

let serialize ?mask t { opcode ; rsv ; final ; content } =
  let open Faraday in
  let b1 = Opcode.to_int opcode lor (rsv lsl 4) in
  write_uint8 t (if final then 0x80 lor b1 else b1) ;
  let len = String.length content in
  let len' =
    if len < 126 then len else if len < 1 lsl 16 then 126 else 127 in
  write_uint8 t (match mask with None -> len' | Some _ -> 0x80 lor len') ;
  begin
    if len' = 126 then BE.write_uint16 t len
    else if len' = 127 then BE.write_uint64 t (Int64.of_int len)
  end ;
  match mask with
  | None ->
    write_string t content
  | Some mask ->
    write_string t mask ;
    String.iteri begin fun i c ->
      write_char t (xor_char c (String.get mask (i mod 4)))
    end content

