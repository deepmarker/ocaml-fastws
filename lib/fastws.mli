(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf

module type CRYPTO = sig
  type buffer
  type g

  val generate : ?g:g -> int -> buffer
  val of_string : string -> buffer
  val to_string : buffer -> string
end

module Crypto : CRYPTO with type buffer = string

val websocket_uuid : string
val extension_parser : string -> (string * string option) list

val headers :
  ?extensions:(string * string option) list ->
  ?protocols:string list ->
  string ->
  Headers.t

module Status : sig
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

  val is_unknown : t -> bool
  val pp : Format.formatter -> t -> unit
  val of_int : int -> t
  val to_int : t -> int
  val of_payload : Bigstringaf.t -> t option
end

module Opcode : sig
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

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val to_int : t -> int
  val is_control : t -> bool
  val is_std : t -> bool
  val is_continuation : t -> bool
  val pp : Format.formatter -> t -> unit
end

module Header : sig
  type t = {
    opcode : Opcode.t;
    rsv : int;
    final : bool;
    length : int;
    mask : string option;
  }
  [@@deriving sexp]

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val show : t -> string

  val create :
    ?rsv:int -> ?final:bool -> ?length:int -> ?mask:string -> Opcode.t -> t

  val xormask : mask:string -> Bigstringaf.t -> unit

  type parse_result = [ `Need of int | `Ok of t * int ]

  val parse : ?pos:int -> ?len:int -> Bigstringaf.t -> parse_result
  val serialize : Faraday.t -> t -> unit
end

module Frame : sig
  type t = { header : Header.t; payload : Bigstringaf.t }

  val compare : t -> t -> int
  val equal : t -> t -> bool
  val pp : Format.formatter -> t -> unit
  val is_text : t -> bool
  val is_binary : t -> bool
  val is_close : t -> bool

  module String : sig
    val empty_text : t
    val empty_binary : t
    val text : string -> t
    val binary : string -> t
    val createf : Opcode.t -> ('a, Format.formatter, unit, t) format4 -> 'a
    val pingf : ('a, Format.formatter, unit, t) format4 -> 'a
    val pongf : ('a, Format.formatter, unit, t) format4 -> 'a
    val textf : ('a, Format.formatter, unit, t) format4 -> 'a
    val binaryf : ('a, Format.formatter, unit, t) format4 -> 'a
    val close : ?status:Status.t * string option -> unit -> t

    val closef :
      ?status:Status.t -> ('a, Format.formatter, unit, t) format4 -> 'a
  end

  module Bigstring : sig
    val text : Bigstringaf.t -> t
    val binary : Bigstringaf.t -> t
    val close : ?status:Status.t * Bigstringaf.t option -> unit -> t
  end
end

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
