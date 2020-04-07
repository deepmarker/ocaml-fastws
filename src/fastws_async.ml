(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Fastws
open Fastws_async_raw

let src = Logs.Src.create "fastws.async"

module Log = (val Logs.src_log src : Logs.LOG)

module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let payload = Bigstring.create 0

type st = {
  buf : Bigbuffer.t;
  monitor : Monitor.t;
  mutable header : Header.t option;
  mutable to_read : int;
  on_pong : Time_ns.Span.t option -> unit;
}

let create_st ?(on_pong = Fn.ignore) () =
  {
    buf = Bigbuffer.create 13;
    monitor = Monitor.create ();
    header = None;
    to_read = 0;
    on_pong;
  }

let reassemble st t =
  if is_header t then Bigbuffer.clear st.buf;
  match (t, st.header) with
  | Header { opcode; final = false; _ }, _ when Opcode.is_control opcode ->
      Format.kasprintf Or_error.error_string "fragmented control frame"
  | ( Header ({ opcode = Text; final = true; _ } as h),
      Some ({ final = false; _ } as h') )
  | ( Header ({ opcode = Binary; final = true; _ } as h),
      Some ({ final = false; _ } as h') )
  | ( Header ({ opcode = Nonctrl _; final = true; _ } as h),
      Some ({ final = false; _ } as h') ) ->
      Format.kasprintf Or_error.error_string "unfinished continuation: %a@.%a"
        Header.pp h Header.pp h'
  | Header { opcode = Continuation; length; _ }, _ ->
      st.to_read <- length;
      Ok `Continue
  | Header ({ length = 0; final = true; _ } as h), _ ->
      st.header <- None;
      Ok (`Frame { Frame.header = h; payload })
  | Header h, _ ->
      st.header <- Some h;
      st.to_read <- h.length;
      Ok `Continue
  | Payload _, None ->
      Log.err (fun m -> m "Got %a" Sexplib.Sexp.pp (sexp_of_t t));
      Format.kasprintf Or_error.error_string "payload without a header"
  | Payload b, Some h -> (
      let buflen = Bigstring.length b in
      match h.final && buflen = st.to_read with
      | true ->
          Bigbuffer.add_bigstring st.buf b;
          st.header <- None;
          let payload = Bigbuffer.big_contents st.buf in
          Ok (`Frame { Frame.header = h; payload })
      | false ->
          Bigbuffer.add_bigstring st.buf b;
          st.to_read <- st.to_read - buflen;
          Ok `Continue )

let r3_of_r2 of_frame st r2 w2 ({ Frame.header; payload } as frame) =
  Log_async.debug (fun m -> m "<- %a" Frame.pp frame) >>= fun () ->
  match header.opcode with
  | Ping ->
      if Bigstring.length payload < 126 then
        write_frame w2 { header = { header with opcode = Pong }; payload }
        >>| fun () -> None
      else (
        Pipe.close_read r2;
        return None )
  | Close ->
      let code =
        match Bigstringaf.length payload with
        | 0 | 1 -> None
        | _ -> Some (Bigstringaf.get_int16_be payload 0)
      in
      Option.iter code ~f:(fun code ->
          Log.debug (fun m ->
              m "Remote endpoint closed connection with code %d" code));
      write_frame_if_open w2 frame >>| fun () ->
      Pipe.close_read r2;
      None
  | Pong -> (
      match Bigstringaf.length payload with
      | 0 ->
          st.on_pong None;
          Log_async.info (fun m -> m "got unsollicited pong with no payload")
          >>| fun () -> None
      | _ -> (
          Log_async.info (fun m -> m "got unsollicited pong with payload")
          >>= fun () ->
          try
            let now = Time_ns.now () in
            let old = Time_ns.of_string (Bigstring.to_string payload) in
            let diff = Time_ns.diff now old in
            Log_async.debug (fun m -> m "<- PONG %a" Time_ns.Span.pp diff)
            >>= fun () ->
            st.on_pong (Some diff);
            return None
          with _ -> return None ) )
  | Text | Binary ->
      assert (Bigstring.length payload = header.length);
      return (Some (of_frame frame))
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
      write_frame w2
        (Frame.Bigstring.close ~status:(Status.UnsupportedExtension, None) ())
      >>| fun () ->
      Pipe.close w2;
      Pipe.close_read r2;
      None

let heartbeat w span =
  let terminated = Ivar.create () in
  let stop = Deferred.any [ Pipe.closed w; Ivar.read terminated ] in
  let write_ping () =
    Log_async.debug (fun m -> m "-> PING") >>= fun () ->
    let ping = Frame.String.pingf "%a" Time_ns.pp (Time_ns.now ()) in
    Fastws_async_raw.write_frame w ping
  in
  Clock_ns.after span >>> fun () ->
  Clock_ns.run_at_intervals' ~continue_on_error:false ~stop span write_ping

let mk_r3 of_frame st r2 w2 =
  Pipe.create_reader ~close_on_exception:false (fun to_r3 ->
      Pipe.transfer' r2 to_r3 ~f:(fun q ->
          let ret = Queue.create () in
          Deferred.Queue.iter q ~f:(fun t ->
              match reassemble st t with
              | Error msg ->
                  let fr =
                    Frame.String.close
                      ~status:
                        ( Status.ProtocolError,
                          Some ("\000\000" ^ Error.to_string_hum msg) )
                      ()
                  in
                  Pipe.write w2 (Header fr.header) >>= fun () ->
                  Pipe.write w2 (Payload fr.payload) >>= fun () ->
                  Pipe.close to_r3;
                  Deferred.unit
              | Ok `Continue -> Deferred.unit
              | Ok (`Frame fr) -> (
                  r3_of_r2 of_frame st r2 w2 fr >>= function
                  | None -> Deferred.unit
                  | Some v ->
                      Queue.enqueue ret v;
                      Deferred.unit ))
          >>| fun () -> ret))

let mk_w3 to_frame w2 =
  Pipe.create_writer (fun from_w3 ->
      Pipe.transfer' from_w3 w2 ~f:(fun pls ->
          let res = Queue.create () in
          Queue.iter pls ~f:(fun pl ->
              let { Frame.header; payload } = to_frame pl in
              Queue.enqueue res (Header header);
              match Bigstring.length payload with
              | 0 -> ()
              | _ -> Queue.enqueue res (Payload payload));
          return res))

type ('r, 'w) t = { r : 'r Pipe.Reader.t; w : 'w Pipe.Writer.t }

let create r w = { r; w }

let connect ?on_pong ?crypto ?extra_headers ?hb ~of_frame ~to_frame url =
  connect ?crypto ?extra_headers url >>= fun (r2, w2) ->
  let st = create_st ?on_pong () in
  Monitor.detach_and_iter_errors st.monitor ~f:(fun exn ->
      Log.err (fun m -> m "%a" Exn.pp exn);
      Pipe.close_read r2;
      Pipe.close w2);
  Option.iter hb ~f:(fun span ->
      Scheduler.within ~monitor:st.monitor (fun () -> heartbeat w2 span));
  let r3 = mk_r3 of_frame st r2 w2 in
  let w3 = mk_w3 to_frame w2 in
  (Pipe.closed r3 >>> fun () -> Pipe.close_read r2);
  ( Deferred.all_unit [ Pipe.closed w3; Pipe.closed r3 ] >>> fun () ->
    Pipe.close w2 );
  return (create r3 w3)

let with_connection ?on_pong ?crypto ?extra_headers ?hb ~of_frame ~to_frame uri
    f =
  connect ?on_pong ?extra_headers ?hb ?crypto ~of_frame ~to_frame uri
  >>= fun { r = r3; w = w3 } ->
  Monitor.protect
    (fun () -> f r3 w3)
    ~finally:(fun () ->
      Pipe.close_read r3;
      Pipe.close w3;
      Deferred.all_unit
        [
          Deferred.ignore_m (Pipe.upstream_flushed r3);
          Deferred.ignore_m (Pipe.upstream_flushed w3);
        ])

let of_frame_s { Frame.payload; _ } = Bigstring.to_string payload

let to_frame_s msg = Frame.String.textf "%s" msg

module type RW = sig
  type r

  type w
end

module MakePersistent (A : RW) = struct
  type nonrec t = (A.r, A.w) t

  module Address = Uri_sexp

  let is_closed { r; w; _ } = Pipe.(is_closed r && is_closed w)

  let close { r; w; _ } =
    Pipe.close w;
    Pipe.close_read r;
    Deferred.unit

  let close_finished { r; w; _ } =
    Deferred.all_unit [ Pipe.closed r; Pipe.closed w ]
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
