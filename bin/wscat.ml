open Core
open Async
open Fastws_async

let src = Logs.Src.create "fastws.async.wscat"

module Lo = (val Logs.src_log src : Logs.LOG)
module Log = (val Logs_async.src_log src : Logs_async.LOG)

let handle_messages r w =
  Deferred.all_unit
    [ Pipe.transfer
        Reader.(pipe @@ Lazy.force stdin)
        w
        ~f:(fun s -> String.chop_suffix_exn s ~suffix:"\n")
    ; Pipe.transfer r Writer.(pipe @@ Lazy.force stderr) ~f:(fun s -> s ^ "\n")
    ]
;;

let main url =
  Random.self_init ();
  Async_uri.with_connection url (fun { r; w; _ } ->
    don't_wait_for
      (Reader.close_finished r >>= fun () -> Log.info (fun m -> m "Reader closed!"));
    don't_wait_for
      (Writer.close_finished w >>= fun () -> Log.info (fun m -> m "Writer closed!"));
    with_connection url r w of_frame_s to_frame_s handle_messages)
;;

let url_cmd = Command.Arg_type.create Uri.of_string

let () =
  Command.async_or_error
    ~summary:"WS console"
    (let open Command.Let_syntax in
     [%map_open
       let () = Logs_async_reporter.set_level_via_param []
       and () = Logs_async_reporter.set_color_via_param ()
       and url = anon ("url" %: url_cmd) in
       fun () ->
         Logs.set_reporter (Logs_async_reporter.reporter ());
         Fastws_async.Raw.to_or_error (main url)])
  |> Command_unix.run
;;
