(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

module type CRYPTO = sig
  type buffer

  val generate : int -> buffer
  val of_string : string -> buffer
  val to_string : buffer -> string
end

module Crypto = struct
  type buffer = string

  let to_string t = t
  let of_string t = t
  let generate len = String.init len (fun _ -> Char.chr @@ Random.int 256)
end

let websocket_uuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

let string_of_exts exts =
  let buf = Buffer.create 128 in
  let len = List.length exts in
  List.iteri
    (fun i (k, v) ->
       Buffer.add_string buf k;
       Option.iter
         (fun x ->
            Buffer.add_char buf '=';
            Buffer.add_string buf x)
         v;
       if i < pred len
       then (
         Buffer.add_char buf ';';
         Buffer.add_char buf ' '))
    exts;
  Buffer.contents buf
;;

let headers ?extensions ?protocols nonce =
  let open Httpun_types in
  let h =
    Headers.of_list
      [ "Upgrade", "websocket"
      ; "Connection", "Upgrade"
      ; "Sec-WebSocket-Key", nonce
      ; "Sec-WebSocket-Version", "13"
      ]
  in
  let h =
    Option.fold protocols ~none:h ~some:(fun ps ->
      Headers.add h "Sec-WebSocket-Protocol" (String.concat ", " ps))
  in
  Option.fold extensions ~none:h ~some:(fun exts ->
    Headers.add h "Sec-WebSocket-Extensions" (string_of_exts exts))
;;

module Status = Status
module Opcode = Opcode
module Header = Header
module Frame = Frame
module Close_frame = Close_frame

(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
