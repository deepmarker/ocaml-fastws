(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Async
open Httpaf

open Fastws

module type CRYPTO = sig
  type buffer
  type g
  val generate: ?g:g -> int -> buffer
  val sha1 : buffer -> buffer
  val to_string: buffer -> string
end

val client :
  ?extra_headers:Headers.t ->
  ?initialized:unit Ivar.t ->
  crypto:(module CRYPTO) ->
  Uri.t ->
  (Frame.t Pipe.Reader.t *
   Frame.t Pipe.Writer.t) Deferred.Or_error.t

(* val client_ez :
 *   ?opcode:Frame.Opcode.t ->
 *   ?extra_headers:Headers.t ->
 *   ?heartbeat:Time_ns.Span.t ->
 *   rng:(module RNG) ->
 *   Uri.t -> Reader.t -> Writer.t ->
 *   string Pipe.Reader.t * string Pipe.Writer.t *)
