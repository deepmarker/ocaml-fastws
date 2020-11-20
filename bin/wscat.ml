open Core
open Async
open Log.Global

let main url =
  Random.self_init ();
  Async_uri.with_connection url (fun { r; w; _ } ->
      Fastws_async.with_connection url r w Fastws_async.of_frame_s
        Fastws_async.to_frame_s (fun r w ->
          Deferred.all_unit
            [
              Pipe.transfer
                Reader.(pipe @@ Lazy.force stdin)
                w
                ~f:(fun s -> String.chop_suffix_exn s ~suffix:"\n");
              Pipe.transfer r
                Writer.(pipe @@ Lazy.force stderr)
                ~f:(fun s -> s ^ "\n");
            ]))

let url_cmd = Command.Arg_type.create Uri.of_string

let () =
  Command.async_or_error ~summary:"WS console"
    (let open Command.Let_syntax in
    [%map_open
      let () = set_level_via_param () and url = anon ("url" %: url_cmd) in
      fun () -> Fastws_async_raw.to_or_error (main url)])
  |> Command.run
