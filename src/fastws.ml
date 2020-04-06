(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Sexplib.Std

module type CRYPTO = sig
  type buffer

  type g

  val generate : ?g:g -> int -> buffer

  val sha_1 : buffer -> buffer

  val of_string : string -> buffer

  val to_string : buffer -> string
end

module Crypto = struct
  type buffer = string

  type g = Random.State.t

  let to_string t = t

  let of_string t = t

  let generate ?(g = Random.get_state ()) len =
    String.init len (fun _ -> Char.chr @@ Random.State.int g 256)

  include Sha1
end

let websocket_uuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

let headers ?protocols nonce =
  ( [
      ("Upgrade", "websocket");
      ("Connection", "Upgrade");
      ("Sec-WebSocket-Key", nonce);
      ("Sec-WebSocket-Version", "13");
    ]
  @
  match protocols with
  | None -> []
  | Some ps -> [ ("Sec-WebSocket-Protocol", String.concat ", " ps) ] )
  |> Httpaf.Headers.of_list

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
    | NormalClosure -> 1000
    | GoingAway -> 1001
    | ProtocolError -> 1002
    | UnsupportedDataType -> 1003
    | InconsistentData -> 1007
    | ViolatesPolicy -> 1008
    | MessageTooBig -> 1009
    | UnsupportedExtension -> 1010
    | UnexpectedCondition -> 1011
    | Unknown status -> status

  let to_bytes t =
    let buf = Bigstringaf.create 2 in
    Bigstringaf.set_int16_be buf 0 (to_int t);
    buf

  let blit buf i t = Bigstringaf.set_int16_be buf i (to_int t)
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

  let compare = Stdlib.compare

  let equal = Stdlib.( = )

  let pp ppf t = Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

  let of_int = function
    | i when i < 0 || i > 0xf -> invalid_arg "Opcode.of_int"
    | 0 -> Continuation
    | 1 -> Text
    | 2 -> Binary
    | 8 -> Close
    | 9 -> Ping
    | 10 -> Pong
    | i when i < 8 -> Nonctrl i
    | i -> Ctrl i

  let to_int = function
    | Continuation -> 0
    | Text -> 1
    | Binary -> 2
    | Close -> 8
    | Ping -> 9
    | Pong -> 10
    | Ctrl i -> i
    | Nonctrl i -> i
end

module Header = struct
  type t = {
    opcode : Opcode.t;
    rsv : int;
    final : bool;
    length : int;
    mask : string option;
  }
  [@@deriving sexp]

  let compare = Stdlib.compare

  let equal = Stdlib.( = )

  let pp ppf t = Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

  let show t = Format.asprintf "%a" pp t

  let create ?(rsv = 0) ?(final = true) ?(length = 0) ?mask opcode =
    { opcode; rsv; final; length; mask }

  let xormask ~mask buf =
    let open Bigstringaf in
    let xor_char a b = Char.(chr (code a lxor code b)) in
    for i = 0 to length buf - 1 do
      set buf i (xor_char (get buf i) mask.[i mod 4])
    done

  type parse_result = [ `Need of int | `Ok of t * int ]

  let parse_aux buf pos len =
    let get_finmask c = Char.code c land 0x80 <> 0 in
    let get_rsv c = (Char.code c lsr 4) land 0x7 in
    let get_len c = Char.code c land 0x7f in
    let get_opcode c = Opcode.of_int (Char.code c land 0xf) in
    let b1 = Bigstringaf.get buf pos in
    let b2 = Bigstringaf.get buf (pos + 1) in
    let final = get_finmask b1 in
    let rsv = get_rsv b1 in
    let opcode = get_opcode b1 in
    let masked = get_finmask b2 in
    let frame_len = get_len b2 in
    match (frame_len, masked) with
    | 126, false ->
        if len < 4 then `Need 4
        else
          let length = Bigstringaf.get_int16_be buf (pos + 2) in
          `Ok (create ~final ~rsv ~length opcode, 4)
    | 126, true ->
        if len < 8 then `Need 8
        else
          let length = Bigstringaf.get_int16_be buf (pos + 2) in
          let mask = Bigstringaf.substring buf ~off:(pos + 4) ~len:4 in
          `Ok (create ~final ~rsv ~length ~mask opcode, 8)
    | 127, false ->
        if len < 10 then `Need 10
        else
          let length = Bigstringaf.get_int64_be buf (pos + 2) in
          let length = Int64.to_int length in
          `Ok (create ~final ~rsv ~length opcode, 10)
    | 127, true ->
        if len < 14 then `Need 14
        else
          let length = Bigstringaf.get_int64_be buf (pos + 2) in
          let length = Int64.to_int length in
          let mask = Bigstringaf.substring buf ~off:(pos + 10) ~len:4 in
          `Ok (create ~final ~rsv ~length ~mask opcode, 14)
    | length, true ->
        if len < 6 then `Need 6
        else
          let mask = Bigstringaf.substring buf ~off:(pos + 2) ~len:4 in
          `Ok (create ~final ~rsv ~mask ~length opcode, 6)
    | length, false -> `Ok (create ~final ~rsv ~length opcode, 2)

  let parse ?(pos = 0) ?len buf =
    let len =
      match len with Some len -> len | None -> Bigstringaf.length buf - pos
    in
    if pos < 0 || len < 2 || pos + len > Bigstringaf.length buf then
      invalid_arg (Printf.sprintf "parse: pos = %d, len = %d" pos len);
    parse_aux buf pos len

  let serialize t { opcode; rsv; final; length; mask } =
    let open Faraday in
    let b1 = Opcode.to_int opcode lor (rsv lsl 4) in
    write_uint8 t (if final then 0x80 lor b1 else b1);
    let len =
      if length < 126 then length else if length < 1 lsl 16 then 126 else 127
    in
    write_uint8 t (match mask with None -> len | Some _ -> 0x80 lor len);
    if len = 126 then BE.write_uint16 t length
    else if len = 127 then BE.write_uint64 t (Int64.of_int length);
    match mask with None -> () | Some mask -> write_string t mask
end

module Frame = struct
  type t = { header : Header.t; payload : Bigstringaf.t }

  let create ?rsv ?final ?mask ?(payload = Bigstringaf.create 0) opcode =
    let length = Bigstringaf.length payload in
    let header = Header.create ?rsv ?final ?mask ~length opcode in
    { header; payload }

  let compare = Stdlib.compare

  let equal = Stdlib.( = )

  let pp ppf = function
    | { header = { opcode = Text; _ } as header; payload } ->
        Format.fprintf ppf "%a [%s]" Sexplib.Sexp.pp (Header.sexp_of_t header)
          Bigstringaf.(
            substring payload ~off:0 ~len:(min 1024 (length payload)))
    | { header; _ } ->
        Format.fprintf ppf "%a <binary data>" Sexplib.Sexp.pp
          (Header.sexp_of_t header)

  let is_binary = function
    | { header = { opcode = Binary; _ }; _ } -> true
    | _ -> false

  let is_text = function
    | { header = { opcode = Text; _ }; _ } -> true
    | _ -> false

  let is_close = function
    | { header = { opcode = Close; _ }; _ } -> true
    | _ -> false

  module String = struct
    (* let kcreate opcode payload =
     *   match payload with
     *   | None -> create opcode
     *   | Some payload -> create ~payload opcode
     * 
     * let text msg = kcreate Text msg
     * 
     * let binary msg = kcreate Binary msg *)

    let tobig f str =
      f
        (let len = String.length str in
         Bigstringaf.of_string str ~off:0 ~len)

    let createf opcode fmt =
      Format.kasprintf (tobig (fun payload -> create ~payload opcode)) fmt

    let pingf fmt = createf Ping fmt

    let pongf fmt = createf Pong fmt

    let textf fmt = createf Text fmt

    let binaryf fmt = createf Binary fmt

    let kclose status msg =
      let msglen = String.length msg in
      let payload = Bigstringaf.create (2 + msglen) in
      Bigstringaf.set_int16_be payload 0 (Status.to_int status);
      Bigstringaf.blit_from_string msg ~src_off:0 payload ~dst_off:2 ~len:msglen;
      { header = Header.create ~length:(2 + msglen) Close; payload }

    let close ?status () =
      match status with
      | None -> create Close
      | Some (st, None) ->
          let payload = Status.to_bytes st in
          create ~payload Close
      | Some (st, Some payload) ->
          let len = String.length payload in
          let payload = Bigstringaf.of_string ~off:0 ~len payload in
          Status.blit payload 0 st;
          create ~payload Close

    let closef ?(status = Status.NormalClosure) fmt =
      Format.kasprintf (kclose status) fmt
  end

  module Bigstring = struct
    let text payload = create Text ?payload

    let binary payload = create Binary ?payload

    let close ?status () =
      match status with
      | None -> create Close
      | Some (st, None) ->
          let payload = Status.to_bytes st in
          create ~payload Close
      | Some (st, Some payload) ->
          Status.blit payload 0 st;
          create ~payload Close
  end
end
