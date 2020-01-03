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
  latency_base : float ;
  latency : int array ;
}

let create_st ?(latency_base=1e4) binary = {
  buf = Bigbuffer.create 13 ;
  monitor = Monitor.create () ;
  header = None ;
  binary ;
  to_read = 0 ;
  latest_ping = None ;
  latest_pong = None ;
  latency_base ;
  latency = Array.create ~len:20 0 ;
}

let histogram { latency_base; latency; _ } = latency_base, latency

let reassemble st t =
  if is_header t then Bigbuffer.clear st.buf ;
  match t, st.header with
  | Header ({ opcode = Text; final = true; _ } as h) , Some ({ final = false ; _ } as h')
  | Header ({ opcode = Binary; final = true; _ } as h), Some ({ final = false ; _ } as h')
  | Header ({ opcode = Nonctrl _; final = true; _ } as h), Some ({ final = false ; _ } as h') ->
    Format.kasprintf (fun msg -> `Fail msg) "unfinished continuation: %a@.%a" Fastws.pp h Fastws.pp h'
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

let compute_bucket latency_base diff =
  let open Float in
  to_int (round_up (log ((Time_ns.Span.to_sec diff *. latency_base) /. log 2.)))

let process rd st client_w r w ({ header ; payload } as frame) =
  match header.opcode with
  | Ping  -> write_frame w { header = { header with opcode = Pong } ; payload }
  | Close -> write_frame w frame >>| fun () -> Pipe.close_read r
  | Pong ->
    begin match payload with
      | None -> invalid_arg "received pong with no payload, aborting"
      | Some payload ->
        assert (Bigstring.length payload = header.length) ;
        try
          let now = Time_ns.now () in
          let cnt = Bigstring.get_int32_le payload ~pos:0 in
          st.latest_pong <- Some (cnt, Time_ns.now ()) ;
          let pingt = snd (Option.value_exn st.latest_ping) in
          let diff = Time_ns.diff now pingt in
          let i = compute_bucket st.latency_base diff in
          if i < Array.length st.latency then
            st.latency.(i) <- succ st.latency.(i)
        with _ ->
          Log.err (fun m -> m "received unidentified pong, aborting") ;
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
        Pipe.write client_w (rd payload)
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
        let diff = Time_ns.diff now ts in
        if diff < Time_ns.Span.(span + span) then
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

let mk_client_read rd st ws_write r =
  Pipe.create_reader ~close_on_exception:false begin fun client_w ->
    Pipe.iter r ~f:begin fun t ->
      match reassemble st t with
      | `Fail msg -> failwith msg
      | `Continue -> Deferred.unit
      | `Frame fr ->
        Scheduler.within' ~monitor:st.monitor
          (fun () -> process rd st client_w r ws_write fr)
    end
  end

let mk_client_write wr st w =
  Pipe.create_writer begin fun ws_read ->
    Pipe.iter ws_read ~f:begin fun m ->
      let { header ; payload } = match st.binary with
        | true -> Fastws.binary (wr m)
        | false -> Fastws.text (wr m) in
      Scheduler.within' ~monitor:st.monitor begin fun () ->
        Pipe.write w (Header header) >>= fun () ->
        match payload with
        | None -> Deferred.unit
        | Some payload -> Pipe.write w (Payload payload)
      end
    end
  end

type ('r, 'w) t = {
  st: st ;
  r: 'r Pipe.Reader.t ;
  w: 'w Pipe.Writer.t ;
}

let create st r w = { st; r; w }

let connect ?crypto ?(binary=false) ?extra_headers ?hb ?latency_base ~of_string ~to_string url =
  connect ?crypto ?extra_headers url >>= fun (r, w) ->
  let st = create_st ?latency_base binary in
  Monitor.detach_and_iter_errors st.monitor ~f:begin fun exn ->
    Log.err (fun m -> m "%a" Exn.pp exn) ;
    Pipe.close_read r ;
    Pipe.close w
  end ;
  Option.iter hb ~f:begin fun span ->
    Scheduler.within ~monitor:st.monitor (fun () -> heartbeat st w span)
  end;
  let client_read  = mk_client_read of_string st w r in
  let client_write = mk_client_write to_string st w in
  (Pipe.closed client_read  >>> fun () -> Pipe.close_read r) ;
  (Pipe.closed client_write >>> fun () -> Pipe.close w) ;
  return (create st client_read client_write)

let with_connection
    ?crypto ?binary ?extra_headers ?hb ?latency_base ~of_string ~to_string uri f =
  connect ?binary ?extra_headers ?hb ?latency_base ?crypto ~of_string ~to_string uri >>= fun { st; r; w } ->
  Monitor.protect (fun () -> f st r w) ~finally:begin fun () ->
    Pipe.close_read r ;
    Pipe.close w ;
    Deferred.unit
  end

module type RW = sig
  type r
  type w
end

module MakePersistent(A: RW) = struct
  type nonrec t = (A.r, A.w) t

  module Address = Uri_sexp

  let is_closed { r; w; _ } =
    Pipe.(is_closed r && is_closed w)

  let close { r; w; _ } =
    Pipe.close w ;
    Pipe.close_read r ;
    Deferred.unit

  let close_finished { r; w; _ } =
    Deferred.all_unit [Pipe.closed r; Pipe.closed w]
end
