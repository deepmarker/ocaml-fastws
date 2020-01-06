open Core
open Async
open Fastws
open Httpaf

type ('r, 'w) t = {
  r: 'r Pipe.Reader.t ;
  w: 'w Pipe.Writer.t ;
}

val connect :
  ?on_pong:(Time_ns.Span.t option -> unit) ->
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  of_string:(string -> 'r) ->
  to_string:('w -> string) ->
  Uri.t -> ('r, 'w) t Deferred.t

val with_connection :
  ?on_pong:(Time_ns.Span.t option -> unit) ->
  ?crypto:(module CRYPTO) ->
  ?binary:bool ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  of_string:(string -> 'r) ->
  to_string:('w -> string) ->
  Uri.t ->
  ('r Pipe.Reader.t -> 'w Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t

module type RW = sig
  type r
  type w
end

module MakePersistent (A : RW) :
  Persistent_connection_kernel.T
  with type t = (A.r, A.w) t and type Address.t = Uri.t
