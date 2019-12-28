open Core
open Async
open Fastws
open Httpaf

type t = {
  r: string Pipe.Reader.t ;
  w: string Pipe.Writer.t ;
}

val connect :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  Uri.t -> t Deferred.Or_error.t

val with_connection :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
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
    ?hb:Time_ns.Span.t ->
    ?on_event:(Event.t -> unit Deferred.t) ->
    ?retry_delay:(unit -> Time_ns.Span.t) ->
    (unit -> address Or_error.t Deferred.t) -> t
end
