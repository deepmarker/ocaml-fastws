(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Sexplib.Std

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
  Httpaf.Headers.of_list @@
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

(* let bytes_of_sexp sexp =
 *   Bytes.unsafe_of_string (string_of_sexp sexp)
 * 
 * let sexp_of_bytes bytes =
 *   sexp_of_string (Bytes.unsafe_to_string bytes) *)

type t = {
  opcode : Opcode.t ;
  rsv : int ;
  final : bool ;
  length : int ;
  mask : string option ;
} [@@deriving sexp]

let compare = Pervasives.compare
let equal = Pervasives.(=)

let pp ppf t =
  Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

let show t = Format.asprintf "%a" pp t

let create ?(rsv=0) ?(final=true) ?(length=0) ?mask opcode =
  { opcode ; rsv ; final ; length ; mask }

type frame = {
  header : t ;
  payload : Bigstringaf.t option ;
}

let pp_frame ppf = function
  | { header ; payload = None } ->
    Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t header)
  | { header ; payload = Some payload } ->
    Format.fprintf ppf "%a [%S]"
      Sexplib.Sexp.pp (sexp_of_t header)
      Bigstringaf.(substring payload ~off:0 ~len:(length payload))

let kcreate opcode content =
  match String.length content with
  | 0 -> { header = create opcode ; payload = None }
  | len ->
    let content = Bigstringaf.of_string ~off:0 ~len content in
    { header = create ~length:(Bigstringaf.length content) opcode ;
      payload = Some content }

let text msg = kcreate Text msg
let binary msg = kcreate Binary msg

let createf opcode fmt = Format.kasprintf (kcreate opcode) fmt
let pingf fmt = Format.kasprintf (kcreate Ping) fmt
let pongf fmt = Format.kasprintf (kcreate Pong) fmt
let textf fmt = Format.kasprintf (kcreate Text) fmt
let binaryf fmt = Format.kasprintf (kcreate Binary) fmt

let kclose status msg =
  let msglen = String.length msg in
  let content = Bigstringaf.create (2 + msglen) in
  Bigstringaf.set_int16_be content 0 (Status.to_int status) ;
  Bigstringaf.blit_from_string msg ~src_off:0 content ~dst_off:2 ~len:msglen ;
  { header = create ~length:(2 + msglen) Close ; payload = Some content }

let close ?(status=Status.NormalClosure) msg =
  kclose status msg

let closef ?(status=Status.NormalClosure) fmt =
  Format.kasprintf (kclose status) fmt

let is_binary = function
  | { header = { opcode = Binary ; _ } ; _ } -> true
  | _ -> false
let is_text = function
  | { header = { opcode = Text ; _ } ; _ } -> true
  | _ -> false
let is_close = function
  | { header = { opcode = Close ; _ } ; _ } -> true
  | _ -> false

let get_finmask c = Char.code c land 0x80 <> 0
let get_rsv c = (Char.code c lsr 4) land 0x7
let get_len c = Char.code c land 0x7f
let get_opcode c = Opcode.of_int (Char.code c land 0xf)
let xor_char a b = Char.(chr (code a lxor code b))

(* let xormask ~mask buf =
 *   Bytes.iteri begin fun i c ->
 *     Bytes.set buf i (xor_char c (String.get mask (i mod 4)))
 *   end buf *)

let xormask ~mask buf =
  let open Bigstringaf in
  for i = 0 to length buf - 1 do
    set buf i (xor_char (get buf i) (String.get mask (i mod 4)))
  done

type parse_result =
  [`More of int | `Ok of t * int]

let parse ?(pos=0) ?len buf =
  let len = match len with
    | Some len -> len
    | None -> Bigstringaf.length buf - pos in
  if pos < 0 || len < 0 || pos + len > Bigstringaf.length buf then
    invalid_arg (Printf.sprintf "parse: pos = %d, len = %d" pos len) ;
  if len < 2 then `More (2 - len)
  else
    let b1 = Bigstringaf.get buf pos in
    let b2 = Bigstringaf.get buf (pos+1) in
    let final = get_finmask b1 in
    let rsv = get_rsv b1 in
    let opcode = get_opcode b1 in
    let masked = get_finmask b2 in
    let frame_len = get_len b2 in
    match frame_len, masked with
    | 126, false ->
      let reql = 2 + 2 in
      if len < reql then `More (reql - len)
      else
        let length = Bigstringaf.get_int16_be buf (pos+2) in
        `Ok (create ~final ~rsv ~length opcode, reql)
    | 126, true ->
      let reql = 2 + 2 + 4 in
      if len < reql then `More (reql - len)
      else
        let length = Bigstringaf.get_int16_be buf (pos+2) in
        let mask = Bigstringaf.substring buf ~off:(pos+4) ~len:4 in
        `Ok ((create ~final ~rsv ~length ~mask opcode), reql)
    | 127, false ->
      let reql = 2 + 8 in
      if len < reql then `More (reql - len)
      else
        let length = Bigstringaf.get_int64_be buf (pos+2) in
        let length = Int64.to_int length in
        `Ok ((create ~final ~rsv ~length opcode), reql)
    | 127, true ->
      let reql = 2 + 8 + 4 in
      if len < reql then `More (reql - len)
      else
        let length = Bigstringaf.get_int64_be buf (pos+2) in
        let length = Int64.to_int length in
        let mask = Bigstringaf.substring buf ~off:(pos+10) ~len:4 in
        `Ok (create ~final ~rsv ~length ~mask opcode, reql)
    | length, true ->
      let reql = 2 + 4 in
      if len < reql then `More (reql - len)
      else
        let mask = Bigstringaf.substring buf ~off:(pos+2) ~len:4 in
        `Ok (create ~final ~rsv ~mask ~length opcode, reql)
    | length, false -> `Ok (create ~final ~rsv ~length opcode, 2)

let serialize t { opcode ; rsv ; final ; length ; mask } =
  let open Faraday in
  let b1 = Opcode.to_int opcode lor (rsv lsl 4) in
  write_uint8 t (if final then 0x80 lor b1 else b1) ;
  let len =
    if length < 126 then length else if length < 1 lsl 16 then 126 else 127 in
  write_uint8 t (match mask with None -> len | Some _ -> 0x80 lor len) ;
  begin
    if len = 126 then BE.write_uint16 t length
    else if len = 127 then BE.write_uint64 t (Int64.of_int length)
  end ;
  match mask with
  | None -> ()
  | Some mask -> write_string t mask
