(* Loopback benchmark of the WebSocket read path over TLS (deepmarker/dm#336).

   [server] streams small text frames on every connection, [burst] frames per
   millisecond tick, like a feed that sends one packet per wakeup. [client]
   opens [conns] connections and reports the CPU, scheduler cycles and read
   syscalls it spent over [secs] seconds, with the decrypted bytes either
   copied through a Unix pipe ([pipe], the path before the change) or read
   straight from async_ssl's pipe ([chunks]). Run the two sides as separate
   processes so that only the client's cost is measured. *)

open Core
open Async

let msg = String.make 120 'x'

let stream_to w ~burst ~lifetime =
  let stop = Option.map lifetime ~f:(fun ms -> Time_float.add (Time_float.now ()) (Time_float.Span.of_ms ms)) in
  let expired () = Option.exists stop ~f:(fun t -> Time_float.(now () > t)) in
  let rec tick () =
    match Pipe.is_closed w, expired () with
    | true, _ -> Deferred.unit
    | false, true ->
      Pipe.close w;
      Deferred.unit
    | false, false ->
      for _ = 1 to burst do
        Pipe.write_without_pushback_if_open w msg
      done;
      after (Time_float.Span.of_ms 1.) >>= tick
  in
  tick ()
;;

let on_conn ~burst ~lifetime _addr _conn r w =
  Fastws_async.Server.accept r w Fastws_async.of_frame_s Fastws_async.to_frame_s
  >>= function
  | Error _ -> Deferred.unit
  | Ok (_request, { Fastws_async.w = out; _ }) -> stream_to out ~burst ~lifetime
;;

let server ~dir ~port ~burst ~lifetime =
  Async_uri.listen_ssl
    ~crt_file:(dir ^/ "localhost.pem")
    ~key_file:(dir ^/ "localhost.key")
    ~on_handler_error:`Ignore
    (Tcp.Where_to_listen.of_port port)
    (on_conn ~burst ~lifetime)
  >>= fun _server -> Deferred.never ()
;;

type snapshot =
  { cpu : float
  ; cycles : int
  ; jobs : int
  ; reads : int
  ; msgs : int
  ; live_words : int
  ; rss_kb : int
  }

let read_syscalls () =
  let line = In_channel.read_lines "/proc/self/io" |> List.find_exn ~f:(String.is_prefix ~prefix:"syscr:") in
  Int.of_string (String.strip (String.chop_prefix_exn line ~prefix:"syscr:"))
;;

let rss_kb () =
  let line =
    In_channel.read_lines "/proc/self/status"
    |> List.find_exn ~f:(String.is_prefix ~prefix:"VmRSS:")
  in
  Scanf.sscanf line "VmRSS: %d kB" Fn.id
;;

let snapshot msgs =
  Gc.full_major ();
  let t = Core_unix.times () in
  { cpu = t.tms_utime +. t.tms_stime
  ; cycles = Async_kernel_scheduler.cycle_count ()
  ; jobs = Async_kernel_scheduler.num_jobs_run ()
  ; reads = read_syscalls ()
  ; msgs = !msgs
  ; live_words = (Gc.stat ()).live_words
  ; rss_kb = rss_kb ()
  }
;;

let consume msgs frames = Pipe.iter_without_pushback frames ~f:(fun _ -> incr msgs)

let start msgs = function
  | Ok { Fastws_async.r; _ } -> don't_wait_for (consume msgs r)
  | Error _ -> failwith "websocket upgrade failed"
;;

let logged = ref false

let log_tls_once (info : Async_uri.Chunked.tls_info) =
  if not !logged
  then (
    logged := true;
    printf "tls: %s %s ktls_recv=%b\n" info.version info.cipher info.ktls_recv)
;;

let connect_one ~mode ~ca_file url =
  match mode with
  | (`Strings | `Direct) as mode ->
    let engine =
      match mode with
      | `Strings -> `Async_ssl
      | `Direct -> `Direct
    in
    Async_uri.Chunked.connect ~engine ~ca_file url
    >>= fun { r; w; tls; _ } ->
    Option.iter tls ~f:log_tls_once;
    Fastws_async.connect url r w Fastws_async.of_frame_s Fastws_async.to_frame_s
  | `Pipe ->
    (* What [connect] did before: a Reader fed by a Unix pipe. *)
    Async_uri.connect ~ca_file url
    >>= fun { r; w; _ } ->
    Fastws_async.connect
      url
      (Async_uri.Chunk_reader.of_reader r)
      w
      Fastws_async.of_frame_s
      Fastws_async.to_frame_s
;;

let open_one ~mode ~ca_file ~msgs url = connect_one ~mode ~ca_file url >>| start msgs

(* Connect, read a few frames, hang up. *)
let churn_once ~server_closes ~mode ~ca_file url =
  connect_one ~mode ~ca_file url
  >>= function
  | Error _ -> failwith "websocket upgrade failed"
  | Ok { Fastws_async.r; w } ->
    (match server_closes with
     | true -> Pipe.iter_without_pushback r ~f:ignore
     | false -> Pipe.read_exactly r ~num_values:5 >>| ignore)
    >>= fun () ->
    Pipe.close_read r;
    Pipe.close w;
    after (Time_float.Span.of_ms 5.)
;;

let open_fds () = Array.length (Stdlib.Sys.readdir "/proc/self/fd")

let churn ~server_closes ~mode ~ca_file ~port ~rounds =
  let url = Uri.make ~scheme:"wss" ~host:"localhost" ~port () in
  let run n = Deferred.List.init ~how:`Sequential n ~f:(fun _ -> churn_once ~server_closes ~mode ~ca_file url) in
  let settle () = after (Time_float.Span.of_sec 1.) >>| fun () -> Gc.full_major () in
  run 50
  >>= fun _ ->
  settle ()
  >>= fun () ->
  let words = (Gc.stat ()).live_words
  and fds = open_fds ()
  and rss = rss_kb () in
  run rounds
  >>= fun _ ->
  settle ()
  >>| fun () ->
  printf
    "%-6s churn rounds=%d  live_words %+d  fds %+d  rss %+d kB\n"
    (match mode with
     | `Pipe -> "pipe"
     | `Strings -> "strings"
     | `Direct -> "direct")
    rounds
    ((Gc.stat ()).live_words - words)
    (open_fds () - fds)
    (rss_kb () - rss)
;;

let client ~mode ~ca_file ~port ~conns ~secs ~warm =
  let url = Uri.make ~scheme:"wss" ~host:"localhost" ~port () in
  let msgs = ref 0 in
  Deferred.List.init ~how:`Sequential conns ~f:(fun _ -> open_one ~mode ~ca_file ~msgs url)
  >>= fun _ ->
  after (Time_float.Span.of_sec warm)
  >>= fun () ->
  let a = snapshot msgs in
  after (Time_float.Span.of_sec secs)
  >>| fun () ->
  let b = snapshot msgs in
  let n = float (b.msgs - a.msgs) in
  let per x y = float (x - y) /. n in
  printf
    "%-6s conns=%d  msg/s=%.0f  cpu=%.1f%%  us/msg=%.1f  cycles/msg=%.3f  jobs/cycle=%.1f  \
     reads/msg=%.3f  live_words %+d  rss %+d kB\n"
    (match mode with
     | `Pipe -> "pipe"
     | `Strings -> "strings"
     | `Direct -> "direct")
    conns
    (n /. secs)
    (100. *. (b.cpu -. a.cpu) /. secs)
    (1e6 *. (b.cpu -. a.cpu) /. n)
    (per b.cycles a.cycles)
    (float (b.jobs - a.jobs) /. float (b.cycles - a.cycles))
    (per b.reads a.reads)
    (b.live_words - a.live_words)
    (b.rss_kb - a.rss_kb)
;;

let () =
  Command_unix.run
    (Command.group
       ~summary:"TLS WebSocket read-path benchmark"
       [ ( "server"
         , Command.async
             ~summary:"stream frames"
             (let%map_open.Command dir = flag "-certs" (required string) ~doc:"DIR certs"
              and port = flag "-port" (required int) ~doc:"PORT listen"
              and burst = flag "-burst" (optional_with_default 2 int) ~doc:"N frames per ms"
              and lifetime = flag "-lifetime-ms" (optional float) ~doc:"MS hang up after" in
              fun () -> server ~dir ~port ~burst ~lifetime) )
       ; ( "churn"
         , Command.async
             ~summary:"connect and hang up repeatedly, report what is left behind"
             (let%map_open.Command ca_file = flag "-ca" (required string) ~doc:"FILE CA"
              and port = flag "-port" (required int) ~doc:"PORT server"
              and mode =
                flag
                  "-mode"
                  (required (Arg_type.of_alist_exn [ "pipe", `Pipe; "strings", `Strings; "direct", `Direct ]))
                  ~doc:"pipe|strings|direct"
              and rounds = flag "-rounds" (optional_with_default 500 int) ~doc:"N"
              and server_closes =
                flag "-server-closes" no_arg ~doc:" wait for the server to hang up"
              in
              fun () -> churn ~server_closes ~mode ~ca_file ~port ~rounds >>| fun () -> shutdown 0) )
       ; ( "client"
         , Command.async
             ~summary:"measure"
             (let%map_open.Command ca_file = flag "-ca" (required string) ~doc:"FILE CA"
              and port = flag "-port" (required int) ~doc:"PORT server"
              and mode =
                flag
                  "-mode"
                  (required (Arg_type.of_alist_exn [ "pipe", `Pipe; "strings", `Strings; "direct", `Direct ]))
                  ~doc:"pipe|strings|direct"
              and conns = flag "-conns" (optional_with_default 8 int) ~doc:"N connections"
              and secs = flag "-secs" (optional_with_default 10. float) ~doc:"S measured"
              and warm = flag "-warm" (optional_with_default 2. float) ~doc:"S warm-up" in
              fun () ->
                client ~mode ~ca_file ~port ~conns ~secs ~warm
                >>| fun () -> shutdown 0) )
       ])
;;
