(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Fastws
open Httpaf

type ('r, 'w) t = { r : 'r Pipe.Reader.t; w : 'w Pipe.Writer.t }

val connect :
  ?on_pong:(Time_ns.Span.t option -> unit) ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  of_frame:(Frame.t -> 'r) ->
  to_frame:('w -> Frame.t) ->
  Uri.t ->
  ('r, 'w) t Deferred.t

val with_connection :
  ?on_pong:(Time_ns.Span.t option -> unit) ->
  ?crypto:(module CRYPTO) ->
  ?extra_headers:Headers.t ->
  ?hb:Time_ns.Span.t ->
  of_frame:(Frame.t -> 'r) ->
  to_frame:('w -> Frame.t) ->
  Uri.t ->
  ('r Pipe.Reader.t -> 'w Pipe.Writer.t -> 'a Deferred.t) ->
  'a Deferred.t

val of_frame_s : Frame.t -> string

val to_frame_s : string -> Frame.t

module type RW = sig
  type r

  type w
end

module MakePersistent (A : RW) :
  Persistent_connection_kernel.T
    with type t = (A.r, A.w) t
     and type Address.t = Uri.t

(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
