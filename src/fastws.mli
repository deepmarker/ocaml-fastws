(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf

module type CRYPTO = sig
  type buffer

  type g

  val generate : ?g:g -> int -> buffer

  val sha_1 : buffer -> buffer

  val of_string : string -> buffer

  val to_string : buffer -> string
end

module Crypto : CRYPTO with type buffer = string

val websocket_uuid : string

val headers : ?protocols:string list -> string -> Headers.t
(** [headers ?protocols nonce] are HTTP headers for client handshake,
   where [nonce] is a "raw" nonce string (not Base64-encoded). *)

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

  val of_int : int -> t

  val to_int : t -> int
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
    val text : Bigstringaf.t option -> t

    val binary : Bigstringaf.t option -> t

    val close : ?status:Status.t * Bigstringaf.t option -> unit -> t
  end
end
