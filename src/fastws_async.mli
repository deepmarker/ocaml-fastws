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

val write_frame : t Pipe.Writer.t -> frame -> unit Deferred.t

type st
val create_st : unit -> st
val reassemble :
  (st -> [`Continue | `Fail of string | `Frame of frame] -> 'a) ->
  st -> t -> 'a

type error =
  | HTTP of Client_connection.error
  | Response of Response.t
  | Timeout of Time_ns.Span.t

val pp_print_error : Format.formatter -> error -> unit

val connect :
  ?timeout:Time_ns.Span.t ->
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  handle:(t Pipe.Writer.t -> t -> unit Deferred.t) ->
  Uri.t ->
  (t Pipe.Writer.t, error) result Deferred.t
(** Closing the resulting writer closes the Websocket connection. *)

val with_connection :
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  handle:(t Pipe.Writer.t -> t -> unit Deferred.t) ->
  f:(t Pipe.Writer.t -> 'a Deferred.t) ->
  Uri.t ->
  ('a, [`User_callback of exn | `WS of error]) result Deferred.t

val connect_ez :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb_ns:Time_stamp_counter.Calibrator.t * Int63.t ->
  Uri.t ->
  (string Pipe.Reader.t * string Pipe.Writer.t * unit Deferred.t,
   [`Internal of exn | `WS of error]) result Deferred.t

val with_connection_ez :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb_ns:Time_stamp_counter.Calibrator.t * Int63.t ->
  Uri.t ->
  f:(string Pipe.Reader.t -> string Pipe.Writer.t -> 'a Deferred.t) ->
  ('a, [`Internal of exn | `User_callback of exn | `WS of error]) result Deferred.t
