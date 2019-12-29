open Core
open Async
open Fastws
open Httpaf

type t = {
  st: st ;
  r: string Pipe.Reader.t ;
  w: string Pipe.Writer.t ;
} and st

val histogram : st -> float * int array
(** [histogram st = (base, histogram)]. [base] is the value which
    multiplies the latency in seconds (by default 1e4, 100us), and
    [histogram] is the number of observations where pongs where between
    base*2^(i-1) and base*2^i *)

val connect :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  ?latency_base:float ->
  Uri.t -> t Deferred.Or_error.t

val with_connection :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  ?latency_base:float ->
  Uri.t ->
  f:(st -> string Pipe.Reader.t -> string Pipe.Writer.t -> 'a Deferred.t) ->
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
