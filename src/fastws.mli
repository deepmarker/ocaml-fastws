(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf

module type CRYPTO = sig
  type buffer
  type g
  val generate: ?g:g -> int -> buffer
  val sha_1 : buffer -> buffer
  val of_string: string -> buffer
  val to_string: buffer -> string
end

module Crypto : CRYPTO with type buffer = string

val websocket_uuid : string

val headers :
  ?protocols:string list  -> string -> Headers.t
(** [headers ?protocols nonce] are headers for client handshake, where
    [nonce] is a "raw" nonce string (not Base64-encoded). *)

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

  val to_int : t -> int
  val pp : Format.formatter -> t -> unit
end

type t = {
  opcode: Opcode.t ;
  extension: int ;
  final: bool ;
  content: string ;
} [@@deriving sexp]

val pp : Format.formatter -> t -> unit
val show : t -> string

val create :
  ?extension:int -> ?final:bool -> ?content:string -> Opcode.t -> t

val ping : t
val pingf : ('a, Format.formatter, unit, t) format4 -> 'a

val pong : t
val pongf : ('a, Format.formatter, unit, t) format4 -> 'a

val close : ?msg:(Status.t * string) -> unit -> t
val closef : Status.t -> ('a, Format.formatter, unit, t) format4 -> 'a

val parser : t Angstrom.t
val serialize : ?mask:string -> Faraday.t -> t -> unit
