(*---------------------------------------------------------------------------
  Copyright (c) 2020 DeepMarker. All rights reserved.
  Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpaf
open Fastws

type t =
  { header : Header.t
  ; payload : string option
  }
[@@deriving sexp_of]

type err =
  [ `Connection_error of Client_connection.error
  | `Invalid_response of Response.t
  | `Timeout
  ]

val to_error : err -> Error.t
val to_or_error : ('a, err) Deferred.Result.t -> 'a Deferred.Or_error.t
val is_header : t -> bool
val write_frame_if_open : t Pipe.Writer.t -> Frame.t -> unit Deferred.t

val connect
  :  ?extra_headers:Httpaf.Headers.t
  -> ?extensions:(string * string option) list
  -> ?protocols:string list
  -> ?timeout:Time_float.Span.t
  -> ?monitor:Monitor.t
  -> Uri.t
  -> Reader.t
  -> Writer.t
  -> ( (string * string option) list * t Pipe.Reader.t * t Pipe.Writer.t
     , err )
     Deferred.Result.t

(**/*)

val serialize : Faraday.t -> Writer.t -> unit Deferred.t

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
