open Core
open Async

let timeout = Time_ns.Span.of_ms 5.
let settle = Time_ns.Span.of_ms 250.
let attempts = 50

let rec drain reader active =
  Reader.read_char reader
  >>= function
  | `Ok _ -> drain reader active
  | `Eof ->
    decr active;
    Deferred.unit
;;

let test_timeout_closes_connection () =
  let active = ref 0 in
  let late_errors = ref 0 in
  let monitor = Monitor.create ~name:"timed-out connections" () in
  Monitor.detach_and_iter_errors monitor ~f:(fun _ -> incr late_errors);
  Tcp.Server.create
    ~on_handler_error:`Raise
    Tcp.Where_to_listen.of_port_chosen_by_os
    (fun _address reader _writer ->
       incr active;
       drain reader active)
  >>= fun server ->
  let port = Tcp.Server.listening_on server in
  let url = Uri.make ~scheme:"wss" ~host:"127.0.0.1" ~port () in
  Deferred.List.iter (List.init attempts ~f:Fn.id) ~how:`Parallel ~f:(fun _ ->
    Scheduler.within' ~monitor (fun () ->
      Fastws_async.connect_or_error ~timeout Fn.id Fn.id url)
    >>| fun result -> assert (Result.is_error result))
  >>= fun () ->
  Clock_ns.after settle
  >>= fun () ->
  let leaked = !active in
  if leaked <> 0 || !late_errors <> 0
  then
    failwithf
      "%d timed-out connections remained open (%d late errors)"
      leaked
      !late_errors
      ()
  else Tcp.Server.close server
;;

let () =
  don't_wait_for
    (Monitor.try_with test_timeout_closes_connection
     >>= function
     | Ok () -> Shutdown.exit 0
     | Error exn ->
       eprintf "%s\n%!" (Exn.to_string exn);
       Shutdown.exit 1);
  never_returns (Scheduler.go ())
;;
