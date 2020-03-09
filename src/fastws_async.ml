open Core
open Async
open Fastws
open Fastws_async_raw

let src = Logs.Src.create "fastws.async"

module Log = (val Logs.src_log src : Logs.LOG)

module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

type st = {
  buf : Bigbuffer.t;
  monitor : Monitor.t;
  binary : bool;
  mutable header : Fastws.t option;
  mutable to_read : int;
  on_pong : Time_ns.Span.t option -> unit;
}

let create_st ?(on_pong = Fn.ignore) binary =
  {
    buf = Bigbuffer.create 13;
    monitor = Monitor.create ();
    header = None;
    binary;
    to_read = 0;
    on_pong;
  }

let reassemble st t =
  if is_header t then Bigbuffer.clear st.buf;
  match (t, st.header) with
  | ( Header ({ opcode = Text; final = true; _ } as h),
      Some ({ final = false; _ } as h') )
  | ( Header ({ opcode = Binary; final = true; _ } as h),
      Some ({ final = false; _ } as h') )
  | ( Header ({ opcode = Nonctrl _; final = true; _ } as h),
      Some ({ final = false; _ } as h') ) ->
      Format.kasprintf
        (fun msg -> `Fail msg)
        "unfinished continuation: %a@.%a" Fastws.pp h Fastws.pp h'
  | Header { opcode = Continuation; length; _ }, _ ->
      st.to_read <- length;
      `Continue
  | Header ({ length = 0; final = true; _ } as h), _ ->
      st.header <- None;
      `Frame { header = h; payload = None }
  | Header h, _ ->
      st.header <- Some h;
      st.to_read <- h.length;
      `Continue
  | Payload _, None ->
      Log.err (fun m -> m "Got %a" Sexplib.Sexp.pp (sexp_of_t t));
      `Fail "payload without a header"
  | Payload b, Some h -> (
      let buflen = Bigstring.length b in
      match h.final && buflen = st.to_read with
      | true ->
          Bigbuffer.add_bigstring st.buf b;
          st.header <- None;
          let payload = Bigbuffer.big_contents st.buf in
          `Frame { header = h; payload = Some payload }
      | false ->
          Bigbuffer.add_bigstring st.buf b;
          st.to_read <- st.to_read - buflen;
          `Continue )

let process rd st client_w r w ({ header; payload } as frame) =
  Log_async.debug (fun m -> m "<- %a" pp_frame frame) >>= fun () ->
  match header.opcode with
  | Ping -> write_frame w { header = { header with opcode = Pong }; payload }
  | Close -> write_frame w frame >>| fun () -> Pipe.close_read r
  | Pong -> (
      match payload with
      | None ->
          st.on_pong None;
          Log_async.info (fun m -> m "got unsollicited pong with no payload")
      | Some payload -> (
          try
            let now = Time_ns.now () in
            let old = Time_ns.of_string (Bigstring.to_string payload) in
            let diff = Time_ns.diff now old in
            Log_async.debug (fun m -> m "<- PONG %a" Time_ns.Span.pp diff)
            >>= fun () ->
            st.on_pong (Some diff);
            Deferred.unit
          with _ ->
            Log_async.info (fun m -> m "got unsollicited pong with payload") ) )
  | Text | Binary -> (
      match payload with
      | None -> Deferred.unit
      | Some payload ->
          assert (Bigstring.length payload = header.length);
          let payload = Bigstring.to_string payload in
          Pipe.write client_w (rd payload) )
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
      write_frame w (close ~status:Status.UnsupportedExtension "") >>| fun () ->
      Pipe.close w;
      Pipe.close_read r

let heartbeat w span =
  let terminated = Ivar.create () in
  let stop = Deferred.any [ Pipe.closed w; Ivar.read terminated ] in
  let write_ping () =
    Log_async.debug (fun m -> m "-> PING") >>= fun () ->
    let ping = Fastws.pingf "%a" Time_ns.pp (Time_ns.now ()) in
    Fastws_async_raw.write_frame w ping
  in
  Clock_ns.after span >>> fun () ->
  Clock_ns.run_at_intervals' ~continue_on_error:false ~stop span write_ping

let mk_client_read rd st ws_write r =
  Pipe.create_reader ~close_on_exception:false (fun client_w ->
      Pipe.iter r ~f:(fun t ->
          match reassemble st t with
          | `Fail msg -> failwith msg
          | `Continue -> Deferred.unit
          | `Frame fr ->
              Scheduler.within' ~monitor:st.monitor (fun () ->
                  process rd st client_w r ws_write fr)))

let mk_client_write wr st w =
  Pipe.create_writer (fun ws_read ->
      Pipe.iter ws_read ~f:(fun m ->
          let { header; payload } =
            match st.binary with
            | true -> Fastws.binary (wr m)
            | false -> Fastws.text (wr m)
          in
          Scheduler.within' ~monitor:st.monitor (fun () ->
              Pipe.write w (Header header) >>= fun () ->
              match payload with
              | None -> Deferred.unit
              | Some payload -> Pipe.write w (Payload payload))))

type ('r, 'w) t = { r : 'r Pipe.Reader.t; w : 'w Pipe.Writer.t }

let create r w = { r; w }

let connect ?on_pong ?crypto ?(binary = false) ?extra_headers ?hb ~of_string
    ~to_string url =
  connect ?crypto ?extra_headers url >>= fun (r, w) ->
  let st = create_st ?on_pong binary in
  Monitor.detach_and_iter_errors st.monitor ~f:(fun exn ->
      Log.err (fun m -> m "%a" Exn.pp exn);
      Pipe.close_read r;
      Pipe.close w);
  Option.iter hb ~f:(fun span ->
      Scheduler.within ~monitor:st.monitor (fun () -> heartbeat w span));
  let client_read = mk_client_read of_string st w r in
  let client_write = mk_client_write to_string st w in
  (Pipe.closed client_read >>> fun () -> Pipe.close_read r);
  ( Deferred.all_unit [ Pipe.closed client_write; Pipe.closed client_read ]
  >>> fun () -> Pipe.close w );
  return (create client_read client_write)

let with_connection ?on_pong ?crypto ?binary ?extra_headers ?hb ~of_string
    ~to_string uri f =
  connect ?on_pong ?binary ?extra_headers ?hb ?crypto ~of_string ~to_string uri
  >>= fun { r; w } ->
  Monitor.protect
    (fun () -> f r w)
    ~finally:(fun () ->
      Pipe.close_read r;
      Pipe.close w;
      Deferred.unit)

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
