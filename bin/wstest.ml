open Core
open Async

let src = Logs.Src.create "fastws.async.wstest"

module Log = (val Logs.src_log src : Logs.LOG)

module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let url_of_test url i =
  let open Uri in
  with_query' (with_path url "runCase")
    [ ("case", string_of_int i); ("agent", "fastws") ]

let of_payload = Option.map ~f:Bigstring.to_string

let to_payload = function
  | None -> Bigstring.create 0
  | Some msg -> Bigstring.of_string msg

let run_test url i =
  Fastws_async.with_connection ~of_payload ~to_payload (url_of_test url i)
    (fun r w ->
      Pipe.iter r ~f:(fun payload ->
          Log_async.debug (fun m ->
              m "Got %S" (Option.value ~default:"" payload))
          >>= fun () -> Pipe.write w payload))

let main url tests =
  Random.self_init ();
  Deferred.List.iter (List.concat tests) ~f:(run_test url)

let url_cmd = Command.Arg_type.create Uri.of_string

let pp_header ppf (l, _) =
  let now = Time_ns.now () in
  Format.fprintf ppf "%a [%a] " Time_ns.pp now Logs.pp_level l

let range_of_string s =
  match String.rsplit2 s ~on:'-' with
  | None -> [ Int.of_string s ]
  | Some (a, b) ->
      let a = Int.of_string a in
      let b = Int.of_string b in
      List.range ~start:`inclusive ~stop:`inclusive a b

let range =
  let open Command.Arg_type in
  comma_separated (map Export.string ~f:range_of_string)

let () =
  Command.async ~summary:"Autobahn test client"
    (let open Command.Let_syntax in
    [%map_open
      let () = Logs_async_reporter.set_level_via_param []
      and url = anon ("url" %: url_cmd)
      and tests = anon ("tests" %: range) in
      fun () ->
        Logs.set_reporter (Logs_async_reporter.reporter ~pp_header ());
        main url tests])
  |> Command.run
