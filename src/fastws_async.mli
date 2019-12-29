open Core
open Async
open Fastws
open Httpaf

type ('r, 'w) t = {
  st: st ;
  r: 'r Pipe.Reader.t ;
  w: 'w Pipe.Writer.t ;
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
  rd:(string -> 'r) ->
  wr:('w -> string) ->
  Uri.t -> ('r, 'w) t Deferred.Or_error.t

val with_connection :
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  ?latency_base:float ->
  rd:(string -> 'r) ->
  wr:('w -> string) ->
  Uri.t ->
  f:(st -> 'r Pipe.Reader.t -> 'w Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.Or_error.t

module type RW = sig
  type r
  type w
end

module MakePersistent (A : RW) :
  Persistent_connection_kernel.T
  with type t = (A.r, A.w) t and type Address.t = Uri.t
