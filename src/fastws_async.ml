open Core
open Async
open Fastws
open Fastws_async_raw

let src = Logs.Src.create "fastws.async.ez"
module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

type st = {
  buf : Bigbuffer.t ;
  monitor : Monitor.t ;
  binary : bool ;
  mutable header : Fastws.t option ;
  mutable to_read : int ;
  mutable latest_ping : (int * Time_ns.t) option ;
  mutable latest_pong : (int * Time_ns.t) option ;
}

let create_st binary = {
  buf = Bigbuffer.create 13 ;
  monitor = Monitor.create () ;
  header = None ;
  binary ;
  to_read = 0 ;
  latest_ping = None ;
  latest_pong = None ;
}

let reassemble st t =
  if is_header t then Bigbuffer.clear st.buf ;
  match t, st.header with
  | Header { opcode; final; _ }, Some { final = false ; _ } when
      final && opcode <> Continuation ->
    `Fail "unfinished continuation"
  | Header { opcode = Continuation ; length ; _ }, _ ->
    st.to_read <- length ;
    `Continue
  | Header ({ length = 0 ; final = true ; _ } as h), _ ->
    st.header <- None ;
    `Frame { header = h ; payload = None }
  | Header h, _ ->
    st.header <- Some h ;
    st.to_read <- h.length ;
    `Continue
  | Payload _, None ->
    Log.err (fun m -> m "Got %a" Sexplib.Sexp.pp (sexp_of_t t)) ;
    `Fail "payload without a header"
  | Payload b, Some h ->
    let buflen = Bigstring.length b in
    match h.final && buflen = st.to_read with
    | true ->
      Bigbuffer.add_bigstring st.buf b ;
      st.header <- None ;
      let payload = Bigbuffer.volatile_contents st.buf in
      let payload = Bigstring.sub_shared ~len:h.length payload in
      `Frame { header = h ; payload = Some payload }
    | false ->
      Bigbuffer.add_bigstring st.buf b ;
      st.to_read <- st.to_read - buflen ;
      `Continue

let process st client_w r w ({ header ; payload } as frame) =
  match header.opcode with
  | Ping  -> write_frame w { header = { header with opcode = Pong } ; payload }
  | Close -> write_frame w frame >>| fun () -> Pipe.close_read r
  | Pong ->
    begin match payload with
      | None -> ()
      | Some payload ->
        assert (Bigstring.length payload = header.length) ;
        try
          let cnt = Bigstring.get_int32_le payload ~pos:0 in
          st.latest_pong <- Some (cnt, Time_ns.now ())
        with _ ->
          Log.err (fun m -> m "Received unidentified pong, aborting") ;
          Pipe.close w ;
          Pipe.close_read r
    end ;
    Deferred.unit
  | Text
  | Binary -> begin match payload with
      | None -> Deferred.unit
      | Some payload ->
        assert (Bigstring.length payload = header.length) ;
        let payload = Bigstring.to_string payload in
        Log_async.debug (fun m -> m "<- %s" payload) >>= fun () ->
        Pipe.write client_w payload
    end
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
    write_frame w (close ~status:Status.UnsupportedExtension "") >>| fun () ->
    Pipe.close w ;
    Pipe.close_read r

let heartbeat st w span =
  let cnt = ref 0 in
  let buf = Bigstring.create 4 in
  let terminated = Ivar.create () in
  let stop = Deferred.any [Pipe.closed w; Ivar.read terminated] in
  let write_ping () =
    Bigstring.set_int32_le buf ~pos:0 (!cnt) ;
    Pipe.write w (Header (create ~length:8 Ping)) >>= fun () ->
    Pipe.write w (Payload buf) >>| fun () ->
    st.latest_ping <- Some (!cnt, Time_ns.now ())
  in
  let send_ping () =
    let now = Time_ns.now () in
    begin match st.latest_ping, st.latest_pong with
      | None, Some _ -> assert false
      | None, _ -> write_ping ()
      | Some (_, ts), None ->
        if Time_ns.diff now ts < Time_ns.Span.(span + span) then
          write_ping ()
        else begin
          Monitor.send_exn st.monitor (Failure "ping timeout") ;
          Ivar.fill_if_empty terminated () ;
          Deferred.unit
        end
      | Some (id, _), Some (id', ts') ->
        if id <> id' then begin
          Monitor.send_exn st.monitor (Failure "unidentified ping payload") ;
          Ivar.fill_if_empty terminated () ;
          Deferred.unit
        end
        else if Time_ns.diff now ts' > Time_ns.Span.(span + span) then begin
          Monitor.send_exn st.monitor (Failure "ping timeout") ;
          Ivar.fill_if_empty terminated () ;
          Deferred.unit
        end
        else write_ping ()
    end
  in
  Clock_ns.run_at_intervals' ~continue_on_error:false ~stop span send_ping

let mk_client_read st ws_write r =
  Pipe.create_reader ~close_on_exception:false begin fun client_w ->
    Pipe.iter r ~f:begin fun t ->
      match reassemble st t with
      | `Fail msg -> failwith msg
      | `Continue -> Deferred.unit
      | `Frame fr ->
        Scheduler.within' ~monitor:st.monitor
          (fun () -> process st client_w r ws_write fr)
    end
  end

let mk_client_write st w =
  Pipe.create_writer begin fun ws_read ->
    Pipe.iter ws_read ~f:begin fun m ->
      let { header ; payload } = match st.binary with
        | true -> Fastws.binary m
        | false -> Fastws.text m in
      Scheduler.within' ~monitor:st.monitor begin fun () ->
        Pipe.write w (Header header) >>= fun () ->
        match payload with
        | None -> Deferred.unit
        | Some payload -> Pipe.write w (Payload payload)
      end
    end
  end

module T = struct
  type t = {
    r: string Pipe.Reader.t ;
    w: string Pipe.Writer.t ;
  }

  let create r w = { r; w }

  module Address = Uri_sexp

  let is_closed { r; _ } = Pipe.is_closed r
  let close { r; w } =
    Pipe.close w ;
    Pipe.close_read r ;
    Deferred.unit

  let close_finished { r; w } =
    Deferred.all_unit [Pipe.closed r ; Pipe.closed w]
end
include T

let connect ?crypto ?(binary=false) ?extra_headers ?hb url =
  connect ?crypto ?extra_headers url >>=? fun (r, w) ->
  let st = create_st binary in
  Monitor.detach_and_iter_errors st.monitor ~f:begin fun exn ->
    Log.err (fun m -> m "%a" Exn.pp exn) ;
    Pipe.close_read r ;
    Pipe.close w
  end ;
  Option.iter hb ~f:begin fun span ->
    Scheduler.within ~monitor:st.monitor (fun () -> heartbeat st w span)
  end;
  let client_read  = mk_client_read st w r in
  let client_write = mk_client_write st w in
  (Pipe.closed client_read  >>> fun () -> Pipe.close_read r) ;
  (Pipe.closed client_write >>> fun () -> Pipe.close w) ;
  Deferred.Or_error.return (create client_read client_write)

let with_connection
    ?(crypto=(module Crypto : CRYPTO))
    ?binary ?extra_headers ?hb uri ~f =
  connect ?binary ?extra_headers ?hb ~crypto uri >>=? fun { r; w } ->
  Monitor.protect begin fun () ->
    Monitor.try_with_or_error (fun () -> f r w)
  end ~finally:begin fun () ->
    Pipe.close_read r ;
    Pipe.close w ;
    Deferred.unit
  end

module Persistent = struct
  include Persistent_connection_kernel.Make(T)

  let create' ~server_name ?crypto ?binary ?extra_headers ?hb ?on_event ?retry_delay =
    let connect url = connect ?crypto ?binary ?extra_headers ?hb url in
    create ~server_name ?on_event ?retry_delay ~connect
end
