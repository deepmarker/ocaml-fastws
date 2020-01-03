open Core
open Async
open Fastws
open Httpaf

type ('r, 'w) t = {
  st: st ;
  r: 'r Pipe.Reader.t ;
  w: 'w Pipe.Writer.t ;
} and st

module Histogram : sig
  type t = private {
    base: float ; (** Multiply the array indices by base*2^i. *)
    mutable sum: Time_ns.Span.t ; (** Sum of latencies (useful for prometheus). *)
    values: int array ; (** Occurences which fall in the corresponding bucket. *)
  }
  val create : ?base:float -> int -> t
  val add : t -> Time_ns.Span.t -> unit
end

val histogram : st -> Histogram.t

val connect :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  ?latency_base:float ->
  of_string:(string -> 'r) ->
  to_string:('w -> string) ->
  Uri.t -> ('r, 'w) t Deferred.t

val with_connection :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  ?latency_base:float ->
  of_string:(string -> 'r) ->
  to_string:('w -> string) ->
  Uri.t ->
  (st -> 'r Pipe.Reader.t -> 'w Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t

module type RW = sig
  type r
  type w
end

module MakePersistent (A : RW) :
  Persistent_connection_kernel.T
  with type t = (A.r, A.w) t and type Address.t = Uri.t
