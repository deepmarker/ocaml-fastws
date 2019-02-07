(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Sexplib.Std
open Httpaf

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

module Frame = struct
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
      | i when (i < 0 || i > 0xf) -> None
      | 0                         -> Some Continuation
      | 1                         -> Some Text
      | 2                         -> Some Binary
      | 8                         -> Some Close
      | 9                         -> Some Ping
      | 10                        -> Some Pong
      | i when i < 8              -> Some (Nonctrl i)
      | i                         -> Some (Ctrl i)

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
    opcode: Opcode.t ;
    extension: int ;
    final: bool ;
    content: string ;
  } [@@deriving sexp]

  let pp ppf t =
    Format.fprintf ppf "%a" Sexplib.Sexp.pp (sexp_of_t t)

  let show t = Format.asprintf "%a" pp t

  let create
      ?(opcode = Opcode.Text) ?(extension=0) ?(final=true) ?(content="") () =
    { opcode ; extension ; final ; content }

  let of_bytes ?opcode ?extension ?final content =
    let content = Bytes.unsafe_to_string content in
    create ?opcode ?extension ?final ~content ()

  let close code =
    let content = Bytes.create 2 in
    EndianBytes.BigEndian.set_int16 content 0 code;
    of_bytes ~opcode:Opcode.Close content
end
