open Core
open Async

(* A peer that goes away does not close the connection: the socket stays
   ESTABLISHED, writes keep succeeding into the kernel's send buffer, and
   nothing fails until TCP stops retransmitting a quarter of an hour later.
   These pin the only signal that says otherwise -- what the peer's
   *application* sends. *)

let span_of_ms ms = Time_ns.Span.of_int_ms ms

(* Feed one end of a pipe as if it were a socket carrying framed websocket
   traffic, and read what the connection writes back. *)
let with_peer ?hb ?max_idle f =
  let to_client_r, to_client_w = Pipe.create () in
  let from_client_r, from_client_w = Pipe.create () in
  let reader = Reader.of_pipe (Info.of_string "peer") to_client_r in
  Writer.of_pipe (Info.of_string "peer") from_client_w
  >>= fun (writer, _) ->
  reader
  >>= fun reader ->
  let conn =
    Fastws_async.of_initialized
      ?hb
      ?max_idle
      reader
      writer
      (Httpun.Headers.of_list [])
      Fn.id
      Fn.id
  in
  (* Drain both directions. Outbound, or the connection's own pings fill the
     pipe and the test blocks on pushback instead of testing anything.
     Inbound, because the liveness stamp happens where frames are handed to
     the application: a caller that stops reading stops refreshing the clock
     and is eventually declared dead, which is deliberate -- a feed nobody is
     draining is not being collected -- but makes an undrained pipe a
     misleading way to test the peer's behaviour. *)
  don't_wait_for (Pipe.iter_without_pushback from_client_r ~f:ignore);
  don't_wait_for (Pipe.iter_without_pushback conn.Fastws_async.r ~f:ignore);
  let send frame =
    let buf = Faraday.create 256 in
    Fastws.Header.serialize buf frame.Fastws.Frame.header;
    Faraday.write_string buf frame.Fastws.Frame.payload;
    Pipe.write_if_open to_client_w (Faraday.serialize_to_string buf)
  in
  (* A wrong answer here must fail, not hang: once the connection is torn down
     nothing drains [to_client_w], so a [send] in a loop that should have
     stopped blocks forever on pushback. *)
  Clock_ns.with_timeout (Time_ns.Span.of_int_sec 20) (f conn ~send)
  >>= fun result ->
  Pipe.close to_client_w;
  match result with
  | `Result r -> return r
  | `Timeout -> failwith "the test blocked"
;;

(* The connection is torn down from the inside, so the caller sees exactly what
   an ordinary disconnect looks like and reconnects the same way. *)
let silence_closes_the_connection () =
  with_peer ~max_idle:(span_of_ms 200) (fun conn ~send:_ ->
    Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) (Pipe.closed conn.Fastws_async.r)
    >>| function
    | `Result () -> ()
    | `Timeout -> failwith "a silent peer left the connection open")
;;

(* A native pong is answered by the peer's websocket library, below and
   independently of whatever produces market data. It attests to the library;
   it says nothing about the feed behind it. A venue whose publisher has wedged
   while its library keeps answering pings is the connection this exists to
   catch, so counting pongs would make exactly that case invisible. *)
let a_native_pong_is_not_liveness () =
  with_peer ~max_idle:(span_of_ms 300) (fun conn ~send ->
    Deferred.repeat_until_finished 20 (fun n ->
      if Pipe.is_closed conn.Fastws_async.r || n = 0
      then return (`Finished ())
      else
        send (Fastws.Frame.String.pong "")
        >>= fun () ->
        Clock_ns.after (span_of_ms 100) >>| fun () -> `Repeat (n - 1))
    >>| fun () ->
    if not (Pipe.is_closed conn.Fastws_async.r)
    then failwith "pongs alone kept the connection alive")
;;

(* Application traffic does count, and a venue's answer to its own text-frame
   heartbeat arrives as one of these like any other frame -- which is the
   reason a venue that defines an application ping wants that one used. *)
let application_traffic_keeps_it_alive () =
  with_peer ~max_idle:(span_of_ms 400) (fun conn ~send ->
    (* Long enough to cover many watchdog periods -- a shorter run could pass
       without the check having fired once -- and checked every round rather
       than at the end, so the failure is reported where it happens instead of
       blocking the next [send]. *)
    Deferred.repeat_until_finished 14 (fun n ->
      if Pipe.is_closed conn.Fastws_async.r
      then failwith "a peer sending data was declared dead";
      if n = 0
      then return (`Finished ())
      else
        send (Fastws.Frame.String.text "{}")
        >>= fun () ->
        Clock_ns.after (span_of_ms 150) >>| fun () -> `Repeat (n - 1)))
;;

let () =
  Thread_safe.block_on_async_exn (fun () ->
    silence_closes_the_connection ()
    >>= fun () ->
    a_native_pong_is_not_liveness () >>= fun () -> application_traffic_keeps_it_alive ());
  printf "fastws liveness: ok\n"
;;
