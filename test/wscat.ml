open Core
open Async

let src = Logs.Src.create "fastws.async.wscat"
module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let main url =
  Fastws_async.with_connection ~wr:Fn.id ~rd:Fn.id url ~f:begin fun _ r w ->
    Deferred.all_unit [
      Pipe.transfer Reader.(pipe @@ Lazy.force stdin) w ~f:begin fun s ->
        String.chop_suffix_exn s ~suffix:"\n"
      end;
      Pipe.transfer r Writer.(pipe @@ Lazy.force stderr) ~f:(fun s -> s ^ "\n")
    ]
  end

let url_cmd = Command.Arg_type.create Uri.of_string

let () =
  Command.async ~summary:"WS console" begin
    let open Command.Let_syntax in
    [%map_open
      let () = Logs_async_reporter.set_level_via_param []
      and url = anon ("url" %: url_cmd) in
      fun () ->
        Logs.set_reporter (Logs_async_reporter.reporter ()) ;
        main url >>= function
        | Ok () -> Deferred.unit
        | Error e -> Error.raise e
    ] end |>
  Command.run
