(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf

val websocket_uuid : string

val headers :
  ?protocols:string list  -> string -> Headers.t
(** [headers ?protocols nonce] are headers for client handshake, where
    [nonce] is a "raw" nonce string (not Base64-encoded). *)

module Frame : sig
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

    val of_int : int -> t option
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
    ?opcode:Opcode.t ->
    ?extension:int ->
    ?final:bool ->
    ?content:string ->
    unit -> t

  val close : int -> t
end
