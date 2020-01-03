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
  latency_base : float ;
  mutable latency_sum : Time_ns.Span.t ;
  latency : int array ;
}

let create_st ?(latency_base=1e3) binary = {
  buf = Bigbuffer.create 13 ;
  monitor = Monitor.create () ;
  header = None ;
  binary ;
  to_read = 0 ;
  latency_base ;
  latency_sum = Time_ns.Span.zero ;
  latency = Array.create ~len:20 0 ;
}

module Histogram = struct
  type t = {
    base: float ;
    mutable sum: Time_ns.Span.t ;
    values: int array ;
  }

  let create ?(base=1e3) len = {
    base ; sum = Time_ns.Span.zero ; values = Array.create ~len 0
  }

  let compute_bucket base diff =
    let open Float in
    to_int (round_up (log ((Time_ns.Span.to_sec diff *. base) /. log 2.)))

  let add t latency =
    let b = compute_bucket t.base latency in
    t.sum <- Time_ns.Span.(t.sum + latency) ;
    t.values.(b) <- succ t.values.(b)
end

let histogram { latency_base; latency_sum; latency; _ } =
  { Histogram.base = latency_base ; sum = latency_sum ; values = latency }

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
      let payload = Bigbuffer.big_contents st.buf in
      `Frame { header = h ; payload = Some payload }
    | false ->
      Bigbuffer.add_bigstring st.buf b ;
      st.to_read <- st.to_read - buflen ;
      `Continue

let process rd st client_w r w ({ header ; payload } as frame) =
  match header.opcode with
  | Ping  -> write_frame w { header = { header with opcode = Pong } ; payload }
  | Close -> write_frame w frame >>| fun () -> Pipe.close_read r
  | Pong ->
    begin match payload with
      | None -> Log.info (fun m -> m "got unsollicited pong, do nothing")
      | Some payload -> try
          let now = Time_ns.now () in
          let old = Time_ns.of_string (Bigstring.to_string payload) in
          let diff = Time_ns.diff now old in
          st.latency_sum <- Time_ns.Span.(st.latency_sum + diff) ;
          Log.info (fun m -> m "<- PONG %a" Time_ns.Span.pp diff) ;
          let i = Histogram.compute_bucket st.latency_base diff in
          if i < Array.length st.latency then
            st.latency.(i) <- succ st.latency.(i)
        with _ ->
          Log.info (fun m -> m "got unsollicited pong, do nothing")
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

let heartbeat w span =
  let terminated = Ivar.create () in
  let stop = Deferred.any [Pipe.closed w; Ivar.read terminated] in
  let write_ping () =
    Log.info (fun m -> m "-> PING") ;
    let ping = Fastws.pingf "%a" Time_ns.pp (Time_ns.now ()) in
    Fastws_async_raw.write_frame w ping in
  Clock_ns.after span >>> fun () ->
  (Clock_ns.run_at_intervals'
     ~continue_on_error:false ~stop span write_ping)

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
    Scheduler.within ~monitor:st.monitor (fun () -> heartbeat w span)
  end;
  let client_read  = mk_client_read of_string st w r in
  let client_write = mk_client_write to_string st w in
  (Pipe.closed client_read  >>> fun () -> Pipe.close_read r) ;
  (Deferred.all_unit [Pipe.closed client_write;
                      Pipe.closed client_read] >>> fun () -> Pipe.close w) ;
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
