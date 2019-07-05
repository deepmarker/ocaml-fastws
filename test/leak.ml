open Core
open Async

(* let uri = Uri.make ~scheme:"https" ~host:"echo.websocket.org" () *)
(* let uri = Uri.make ~scheme:"http" ~host:"demos.kaazing.com" ~path:"echo" () *)
let uri = Uri.make ~scheme:"https" ~host:"ws-beta.kraken.com" ()

let rec loop () =
  Logs_async.app (fun m -> m "Connecting to %a" Uri.pp uri) >>= fun () ->
  Fastws_async.connect_ez uri >>= function
  | Error _ -> assert false
  | Ok (r, w, _) ->
  Logs_async.app (fun m -> m "Connected to %a" Uri.pp uri) >>= fun () ->
  Clock_ns.after (Time_ns.Span.of_int_sec 3) >>= fun () ->
  Pipe.close_read r;
  Pipe.close w;
  loop ()

let cmd =
  Command.async ~summary:"Leak test" begin
    let open Command.Let_syntax in
    [%map_open
      let () = Logs_async_reporter.set_level_via_param None in
      fun () ->
        Logs.set_reporter (Logs_async_reporter.reporter ()) ;
        loop ()
    ]
  end

let () = Command.run cmd
