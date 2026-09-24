(* A WebSocket echo server, the smallest use of [Fastws_async.Server]: every
   text or binary frame a client sends comes back as text.

   Run: dune exec lib/fastws/bin/wsecho.exe -- -port 9001 *)

open Core
open Async

let () =
  Command_unix.run
    (Command.async
       ~summary:"WebSocket echo server"
       (let%map_open.Command port =
          flag
            "port"
            (optional_with_default 9001 int)
            ~doc:"PORT listen on (default 9001)"
        in
        fun () ->
          Fastws_async.Server.serve
            ~on_refused:(fun addr e ->
              eprintf
                !"refused %{Socket.Address.Inet}: %s\n%!"
                addr
                (Error.to_string_hum e))
            (Tcp.Where_to_listen.of_port port)
            (fun (f : Fastws.Frame.t) -> f.payload)
            (Fastws.Frame.String.textf "%s")
            (fun _addr request conn ->
               printf "connected: %s\n%!" request.target;
               Pipe.transfer_id conn.r conn.w)
          >>= fun (_ : (Socket.Address.Inet.t, int) Tcp.Server.t) ->
          printf "listening on %d\n%!" port;
          Deferred.never ()))
;;
