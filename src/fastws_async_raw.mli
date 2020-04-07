(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Fastws

type t = Header of Header.t | Payload of Bigstring.t [@@deriving sexp_of]

val is_header : t -> bool

val write_frame : t Pipe.Writer.t -> Frame.t -> unit Deferred.t

val write_frame_if_open : t Pipe.Writer.t -> Frame.t -> unit Deferred.t

val connect :
  ?version:Async_ssl.Version.t ->
  ?options:Async_ssl.Opt.t list ->
  ?socket:([ `Unconnected ], Socket.Address.Inet.t) Socket.t ->
  ?crypto:(module Fastws.CRYPTO) ->
  ?extra_headers:Httpaf.Headers.t ->
  (Uri.t -> (t Pipe.Reader.t * t Pipe.Writer.t) Deferred.t)
  Tcp.with_connect_options

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
