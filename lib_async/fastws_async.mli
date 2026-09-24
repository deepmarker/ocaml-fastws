(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpun
open Fastws

type ('r, 'w) t =
  { r : 'r Pipe.Reader.t
  ; w : 'w Pipe.Writer.t
  }

(** [max_idle] declares the connection dead when the peer's application has
    sent nothing -- no data, no application-level reply -- for that long,
    closing both pipes so the caller sees an ordinary disconnect and
    reconnects.

    A connection whose peer has gone away does not fail on its own. Writes
    still succeed into the kernel's send buffer, and the error only arrives
    when TCP stops retransmitting, which on a default Linux is about fifteen
    minutes; a host resuming from suspend spends all of it looking connected
    and delivering nothing. Only inbound traffic says the peer is there.

    Only Text and Binary reset it. A native pong deliberately does not: RFC
    6455 ping/pong is answered by the peer's websocket library, below whatever
    produces the data, so it attests to the library and not to the feed behind
    it. [hb] therefore keeps the socket warm and is not evidence of life, and
    a deadline here has to be sized against the venue's own application-level
    heartbeat rather than against [hb]. *)

val of_initialized
  :  ?src:Logs.src
  -> ?on_pong:(Time_ns.t option -> unit)
       (** Called once for the first valid Close frame received from the peer,
      before the connection pipes are closed. It is not called for EOF or a
      locally initiated close. *)
  -> ?on_close:(Close_frame.t -> unit)
  -> ?monitor:Monitor.t
  -> ?hb:Time_ns.Span.t
  -> ?max_idle:Time_ns.Span.t
  -> Reader.t
  -> Writer.t
  -> Headers.t
  -> (Frame.t -> 'a)
  -> ('b -> Frame.t)
  -> ('a, 'b) t

val connect
  :  ?src:Logs.src
  -> ?on_pong:(Time_ns.t option -> unit)
  -> ?on_close:(Close_frame.t -> unit)
  -> ?extra_headers:Headers.t
  -> ?extensions:(string * string option) list
  -> ?protocols:string list
  -> ?monitor:Monitor.t
  -> ?hb:Time_ns.Span.t
  -> ?max_idle:Time_ns.Span.t
  -> Uri.t
  -> Reader.t
  -> Writer.t
  -> (Frame.t -> 'r)
  -> ('w -> Frame.t)
  -> (('r, 'w) t, Fastws_async_raw.err) Deferred.Result.t

val with_connection
  :  ?src:Logs.src
  -> ?on_pong:(Time_ns.t option -> unit)
  -> ?on_close:(Close_frame.t -> unit)
  -> ?extra_headers:Headers.t
  -> ?extensions:(string * string option) list
  -> ?protocols:string list
  -> ?monitor:Monitor.t
  -> ?hb:Time_ns.Span.t
  -> ?max_idle:Time_ns.Span.t
  -> Uri.t
  -> Reader.t
  -> Writer.t
  -> (Frame.t -> 'r)
  -> ('w -> Frame.t)
  -> ('r Pipe.Reader.t -> 'w Pipe.Writer.t -> 'a Deferred.t)
  -> ('a, Fastws_async_raw.err) Deferred.Result.t

val with_connection'
  :  ?src:Logs.src
  -> ?on_pong:(Time_ns.t option -> unit)
  -> ?on_close:(Close_frame.t -> unit)
  -> ?extra_headers:Headers.t
  -> ?extensions:(string * string option) list
  -> ?protocols:string list
  -> ?monitor:Monitor.t
  -> ?hb:Time_ns.Span.t
  -> ?max_idle:Time_ns.Span.t
  -> Uri.t
  -> Reader.t
  -> Writer.t
  -> (Frame.t -> 'r)
  -> ('w -> Frame.t)
  -> ('r Pipe.Reader.t -> 'w Pipe.Writer.t -> 'a Deferred.t)
  -> 'a Deferred.Or_error.t

val of_frame_s : Frame.t -> string
val to_frame_s : string -> Frame.t

val connect_or_result
  :  ?src:Logs.src
  -> ?on_pong:(Time_ns.t option -> unit)
  -> ?on_close:(Close_frame.t -> unit)
  -> ?extra_headers:Headers.t
  -> ?extensions:(string * string option) list
  -> ?protocols:string list
  -> ?monitor:Monitor.t
  -> ?hb:Time_ns.Span.t
  -> ?max_idle:Time_ns.Span.t
  -> (Frame.t -> 'r)
  -> ('w -> Frame.t)
  -> Uri.t
  -> (('r, 'w) t, Fastws_async_raw.err) Deferred.Result.t

val connect_or_error
  :  ?src:Logs.src
  -> ?timeout:Time_ns.Span.t
  -> ?on_pong:(Time_ns.t option -> unit)
  -> ?on_close:(Close_frame.t -> unit)
  -> ?extra_headers:Headers.t
  -> ?extensions:(string * string option) list
  -> ?protocols:string list
  -> ?monitor:Monitor.t
  -> ?hb:Time_ns.Span.t
  -> ?max_idle:Time_ns.Span.t
  -> (Frame.t -> 'r)
  -> ('w -> Frame.t)
  -> Uri.t
  -> ('r, 'w) t Deferred.Or_error.t

(** The server side: accept WebSocket upgrades on a socket (RFC 6455,
    section 4.2). The connection a server gets is the same [('r, 'w) t] a
    client gets from {!connect}, with outgoing frames unmasked as a server's
    must be. permessage-deflate is not offered, which the RFC allows: clients
    then exchange plain frames. *)
module Server : sig
  type request =
    { target : string (** path and query of the upgrade request *)
    ; headers : Httpun.Headers.t
    }

  (** Read the client's upgrade request from [r], check it, and answer on [w]:
      101 and the connection on success; 426 (with the supported version) for
      a [Sec-WebSocket-Version] other than 13; 400 for anything else that is
      not an upgrade request. The request head is bounded (16 KiB, 100 lines).

      [protocol] picks one of the subprotocols the client offered, in the
      order offered; by default none is. [extra_headers] go on the 101. The
      other optional arguments are those of {!of_initialized}. *)
  val accept
    :  ?src:Logs.src
    -> ?on_pong:(Time_ns.t option -> unit)
    -> ?on_close:(Close_frame.t -> unit)
    -> ?monitor:Monitor.t
    -> ?hb:Time_ns.Span.t
    -> ?max_idle:Time_ns.Span.t
    -> ?protocol:(string list -> string option)
    -> ?extra_headers:(string * string) list
    -> Reader.t
    -> Writer.t
    -> (Frame.t -> 'a)
    -> ('b -> Frame.t)
    -> (request * ('a, 'b) t) Deferred.Or_error.t

  (** A TCP server that runs [handler] on each accepted WebSocket connection
      and closes the connection when it returns. Requests refused by
      {!accept} are answered and reported to [on_refused]. *)
  val serve
    :  ?src:Logs.src
    -> ?on_pong:(Time_ns.t option -> unit)
    -> ?on_close:(Close_frame.t -> unit)
    -> ?monitor:Monitor.t
    -> ?hb:Time_ns.Span.t
    -> ?max_idle:Time_ns.Span.t
    -> ?protocol:(string list -> string option)
    -> ?extra_headers:(string * string) list
    -> ?on_refused:(Socket.Address.Inet.t -> Error.t -> unit)
    -> (Socket.Address.Inet.t, 'port) Tcp.Where_to_listen.t
    -> (Frame.t -> 'a)
    -> ('b -> Frame.t)
    -> (Socket.Address.Inet.t -> request -> ('a, 'b) t -> unit Deferred.t)
    -> (Socket.Address.Inet.t, 'port) Tcp.Server.t Deferred.t
end

module Raw = Fastws_async_raw

(** Exposed only so the fragment reassembler can be tested: it is reached
    in production through {!of_initialized} and a live socket, which is not
    a thing a unit test can hold. *)
module For_testing : sig
  (** Feed frames through one connection's reassembler in order. [Ok None]
      is a fragment absorbed, [Ok (Some f)] a message or control frame
      handed on, and [Error] a protocol violation by the peer. *)
  val reassemble : Fastws.Frame.t list -> Fastws.Frame.t option Or_error.t list

  (** Whether a frame's header passes the pre-reassembly check, on a
      connection that did ([deflate:true]) or did not negotiate
      permessage-deflate. [false] means the connection is failed with 1002. *)
  val check_hdr : deflate:bool -> Fastws.Frame.t -> bool
end

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
