(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Sexplib.Std

open Httpaf

let websocket_uuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

let headers ?protocols nonce =
  Headers.of_list @@
  ("Upgrade", "websocket") ::
  ("Connection", "Upgrade") ::
  ("Sec-WebSocket-Key", B64.encode nonce) ::
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
  extension : int ;
  final : bool ;
  content: string ;
} [@@deriving sexp]

let pp ppf t =
  Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

let show t = Format.asprintf "%a" pp t

let create ?(extension=0) ?(final=true) ?(content="") opcode =
  { opcode ; extension ; final ; content }

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
  | Data of int64

type state = {
  pos : pos ;
  buf : Buffer.t ;
  mask : bytes option ;
  len : int64 ;
}

let start = {
  pos = Hdr1 ;
  buf = Buffer.create 13 ;
  mask = None ;
  len = 0L
}

let get_finmask c = Char.code c land 0x80 <> 0
let get_extension c = (Char.code c lsr 4) land 0x7
let get_len c = Char.code c land 0x7f
let get_opcode c = Opcode.of_int (Char.code c land 0xf)

let xor_char a b =
  Char.(chr (code a lxor code b))

let parser =
  let open Angstrom in
  lift snd @@
  scan_state (start, create Opcode.Text) begin fun (state, frame) c ->
    match state.pos with
    | Hdr1 ->
      let final = get_finmask c in
      let extension = get_extension c in
      let opcode = get_opcode c in
      Some ({ start with pos = Hdr2 },
            create ~extension ~final opcode)
    | Hdr2 ->
      let state =
        if get_finmask c then
          { state with mask = Some (Bytes.create 4) }
        else state in
      begin
        match get_len c with
        | 126 -> Some ({ state with pos = Len 2 }, frame)
        | 127 -> Some ({ state with pos = Len 8 }, frame)
        | n when state.mask = None ->
          let len = Int64.of_int n in
          Some ({ state with pos = Data len ; len }, frame)
        | n ->
          let len = Int64.of_int n in
          Some ({ state with pos = Mask 4 ; len }, frame)
      end
    | Len 0 -> begin
        match state.mask with
        | Some _ -> Some ({ state with pos = Mask 4 }, frame)
        | None -> Some ({ state with pos = Data state.len }, frame)
      end
    | Len n ->
      let open Int64 in
      let len = add state.len
          (shift_left (of_int (Char.code c)) (n - 1)) in
      Some ({ state with pos = Len (n - 1) ; len }, frame)
    | Mask 0 -> Some ({ state with pos = Data state.len }, frame)
    | Mask n -> begin
        match state.mask with
        | None -> assert false
        | Some buf ->
          Bytes.set buf (n - 4) c ;
          Some ({ state with pos = Mask (pred n) }, frame)
      end
    | Data 0L ->
      let content = begin
        match state.mask with
        | None -> Buffer.contents state.buf
        | Some mask ->
          let buf = Buffer.to_bytes state.buf in
          let open Bytes in
          iteri begin fun i c ->
            set buf i (xor_char c (get mask (i mod 4)))
          end buf ;
          unsafe_to_string buf
      end in
      Some (state, { frame with content })
    | Data n ->
      Buffer.add_char state.buf c ;
      Some ({ state with pos = Data (Int64.pred n) }, frame)
  end

let serialize ?mask t { opcode ; extension ; final ; content } =
  let open Faraday in
  let b1 = Opcode.to_int opcode lor (extension lsl 4) in
  let len = String.length content in
  write_uint8 t (if final then 0x80 lor b1 else b1) ;
  let len' =
    if len < 126 then len else if len < 1 lsl 16 then 126 else 127 in
  write_uint8 t (match mask with None -> len' | Some _ -> 0x80 lor len') ;
  if len' = 126 then BE.write_uint16 t len
  else if len' = 127 then BE.write_uint64 t (Int64.of_int len) ;
  begin
    match mask with
    | None -> ()
    | Some m -> write_string t m
  end ;
  write_string t content

