open Core
open Async

(* let uri = Uri.make ~scheme:"https" ~host:"echo.websocket.org" () *)
(* let uri = Uri.make ~scheme:"http" ~host:"demos.kaazing.com" ~path:"echo" () *)
let url = Uri.make ~scheme:"https" ~host:"ftx.com" ~path:"ws/" ()

(* This does not leak. *)
(* let rec inner = function
 *   | n when n < 0 -> invalid_arg "inner"
 *   | 0 -> Deferred.unit
 *   | n ->
 *     Fastws_async.connect uri >>= function
 *     | Error _ -> failwith "fastws error"
 *     | Ok { r; w; _ } ->
 *       Pipe.close_read r ;
 *       Pipe.close w ;
 *       Logs_async.app (fun m -> m "inner %d" n) >>= fun _ ->
 *       Clock_ns.after (Time_ns.Span.of_int_sec 3) >>= fun () ->
 *       inner (pred n) *)

let rec inner = function
  | 0 -> Deferred.unit
  | n when n > 0 ->
    Async_uri.with_connection url (fun { r; w; _ } ->
      Fastws_async.with_connection
        url
        r
        w
        Fastws_async.of_frame_s
        Fastws_async.to_frame_s
        (fun _r _w -> Logs_async.app (fun m -> m "inner %d" n)))
    >>= fun _ -> Clock_ns.after (Time_ns.Span.of_int_sec 3) >>= fun () -> inner (pred n)
  | _ -> invalid_arg "inner"
;;

(* This does not leak. *)
(* let rec inner = function
 *   | n when n < 0 -> invalid_arg "inner"
 *   | 0 -> Deferred.unit
 *   | n ->
 *     Fastws_async_raw.connect uri >>= function
 *     | Error _ -> failwith "fastws error"
 *     | Ok (r, w) ->
 *       Pipe.close_read r ;
 *       Pipe.close w ;
 *       Logs_async.app (fun m -> m "inner %d" n) >>= fun _ ->
 *       Clock_ns.after (Time_ns.Span.of_int_sec 3) >>= fun () ->
 *       inner (pred n) *)

let cmd =
  Command.async
    ~summary:"Leak test"
    (let open Command.Let_syntax in
     [%map_open
       let () = Logs_async_reporter.set_level_via_param []
       and n = anon ("n" %: int) in
       fun () ->
         Logs.set_reporter (Logs_async_reporter.reporter ());
         inner n])
;;

let () = Command_unix.run cmd
