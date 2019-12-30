(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Fastws

type t =
  | Header of Fastws.t
  | Payload of Bigstring.t
[@@deriving sexp_of]

val is_header : t -> bool
val write_frame : t Pipe.Writer.t -> frame -> unit Deferred.t

val connect:
  ?version:Async_ssl.Version.t ->
  ?options:Async_ssl.Opt.t sexp_list ->
  ?socket:([ `Unconnected ], Socket.Address.Inet.t) Socket.t ->
  ?buffer_age_limit:[ `At_most of Time.Span.t | `Unlimited ] ->
  ?interrupt:unit Deferred.t ->
  ?reader_buffer_size:int ->
  ?writer_buffer_size:int ->
  ?timeout:Time.Span.t ->
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Httpaf.Headers.t ->
  Uri.t -> (t Pipe.Reader.t * t Pipe.Writer.t) Deferred.t
