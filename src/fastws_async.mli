(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpaf

open Fastws

module type CRYPTO = sig
  type buffer
  type g
  val generate: ?g:g -> int -> buffer
  val sha1 : buffer -> buffer
  val of_string: string -> buffer
  val to_string: buffer -> string
end

val connect :
  ?extra_headers:Headers.t ->
  crypto:(module CRYPTO) ->
  Uri.t ->
  (t Pipe.Reader.t * t Pipe.Writer.t) Deferred.t

val with_connection :
  ?extra_headers:Headers.t ->
  crypto:(module CRYPTO) ->
  Uri.t ->
  f:(t Pipe.Reader.t -> t Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t

exception Timeout of Int63.t

val connect_ez :
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb_ns:Int63.t ->
  crypto:(module CRYPTO) ->
  Uri.t ->
  (string Pipe.Reader.t * string Pipe.Writer.t) Deferred.t

val with_connection_ez :
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb_ns:Int63.t ->
  crypto:(module CRYPTO) ->
  Uri.t ->
  f:(string Pipe.Reader.t -> string Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t
