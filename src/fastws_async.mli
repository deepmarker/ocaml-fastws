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

val connect :
  ?timeout:Time_ns.Span.t ->
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  Uri.t ->
  (t Pipe.Reader.t * t Pipe.Writer.t) Deferred.Or_error.t
(** Closing the resulting writer closes the Websocket connection. *)

val with_connection :
  ?stream:Faraday.t ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  f:(t Pipe.Reader.t -> t Pipe.Writer.t -> 'a Deferred.t) ->
  Uri.t -> 'a Deferred.Or_error.t

module EZ : sig
  type t = {
    r: string Pipe.Reader.t ;
    w: string Pipe.Writer.t ;
    cleaned_up: unit Deferred.t ;
  }

  val connect :
    ?crypto:(module CRYPTO) ->
    ?binary:bool ->
    ?extra_headers:Headers.t ->
    ?hb_ns:Time_stamp_counter.Calibrator.t * Int63.t ->
    Uri.t -> t Deferred.Or_error.t

  val with_connection :
    ?crypto:(module CRYPTO) ->
    ?binary:bool ->
    ?extra_headers:Headers.t ->
    ?hb_ns:Time_stamp_counter.Calibrator.t * Int63.t ->
    Uri.t ->
    f:(string Pipe.Reader.t -> string Pipe.Writer.t -> 'a Deferred.t) ->
    'a Deferred.Or_error.t

  module Persistent : sig
    include Persistent_connection_kernel.S
      with type address = Uri.t
       and type conn = t

    val create' :
      server_name:string ->
      ?crypto:(module CRYPTO) ->
      ?binary:bool ->
      ?extra_headers:Headers.t ->
      ?hb_ns:Time_stamp_counter.Calibrator.t * Int63.t ->
      ?on_event:(Event.t -> unit Deferred.t) ->
      ?retry_delay:(unit -> Time_ns.Span.t) ->
      (unit -> address Or_error.t Deferred.t) -> t
  end
end
