(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpaf
open Fastws

type t =
  | Header of Fastws.t
  | Payload of Bigstringaf.t

val connect :
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  Uri.t ->
  handle:(t -> unit Deferred.t) ->
  t Pipe.Writer.t Deferred.t

val with_connection :
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  Uri.t ->
  handle:(t -> unit Deferred.t) ->
  f:(t Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t

exception Timeout of Int63.t

val connect_ez :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb_ns:Int63.t ->
  Uri.t ->
  (string Pipe.Reader.t * string Pipe.Writer.t) Deferred.t

val with_connection_ez :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb_ns:Int63.t ->
  Uri.t ->
  f:(string Pipe.Reader.t -> string Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t
