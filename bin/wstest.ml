open Core
module Time_ns = Time_ns_unix
open Async
open Fastws

let src = Logs.Src.create "fastws.async.wstest"

module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let url_of_test url prefix i =
  let open Uri in
  with_query'
    (with_path url "runCase")
    [ "casetuple", prefix ^ "." ^ string_of_int i; "agent", "fastws" ]
;;

let run_test url section j =
  Async_uri.with_connection url (fun { r; w; _ } ->
    Fastws_async.with_connection (url_of_test url section j) r w Fn.id Fn.id (fun r w ->
      Pipe.iter r ~f:(fun (fr : Frame.t) -> Pipe.write w fr)))
;;

let main url section tests =
  Random.self_init ();
  Deferred.Or_error.List.iter ~how:`Sequential (List.concat tests) ~f:(fun x ->
    Fastws_async.Raw.to_or_error (run_test url section x))
;;

let url_cmd = Command.Arg_type.create Uri.of_string

let range_of_string s =
  match String.rsplit2 s ~on:'-' with
  | None -> [ Int.of_string s ]
  | Some (a, b) ->
    let a = Int.of_string a in
    let b = Int.of_string b in
    List.range ~start:`inclusive ~stop:`inclusive a b
;;

let range =
  let open Command.Arg_type in
  comma_separated (map Export.string ~f:range_of_string)
;;

let () =
  Command.async_or_error
    ~summary:"Autobahn test client"
    (let open Command.Let_syntax in
     [%map_open
       let () = Logs_async_reporter.set_level_via_param []
       and url = anon ("url" %: url_cmd)
       and section = anon ("section" %: string)
       and tests = anon ("tests" %: range) in
       fun () ->
         Logs.set_reporter (Logs_async_reporter.reporter ());
         main url section tests])
  |> Command_unix.run
;;
