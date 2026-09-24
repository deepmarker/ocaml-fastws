(* Autobahn test suite client driver.

   Drives [wstest -m fuzzingserver] the way the suite expects a client under
   test to: ask how many cases the server was configured with, echo every
   message back for each case in turn, then ask the server to write the
   report. The suite decides pass or fail; this program only has to be a
   faithful echo and to not fall over when a case is designed to make it. *)

open Core
module Time_ns = Time_ns_unix
open Async
open Fastws

let src = Logs.Src.create "fastws.async.wstest"

module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let endpoint url path query =
  Uri.with_query' (Uri.with_path url path) query
;;

(* Every case is run on its own connection, and a case that fails does so by
   killing that connection -- which is the point of most of them. So errors are
   logged and swallowed: the run has to reach [updateReports] or there is no
   report to read. *)
let with_ws url f =
  let run () =
    Async_uri.with_connection url (fun { r; w; _ } ->
      Fastws_async.with_connection ~src url r w Fn.id Fn.id f)
  in
  Monitor.try_with ~extract_exn:true run
  >>= function
  | Error exn -> return (Or_error.of_exn exn)
  | Ok (Error _) -> return (Or_error.error_string "connection failed")
  | Ok (Ok v) -> return (Ok v)
;;

(* /getCaseCount answers with a single text frame holding the number, then
   closes. *)
let get_case_count url =
  let count = ref None in
  with_ws (endpoint url "getCaseCount" [])
    (fun r _w ->
       Pipe.iter r ~f:(fun (fr : Frame.t) ->
         (match Int.of_string_opt (String.strip fr.payload) with
          | Some n -> count := Some n
          | None -> ());
         Deferred.unit))
  >>| fun res ->
  match res, !count with
  | _, Some n -> Ok n
  | Error e, None -> Error e
  | Ok (), None -> Or_error.error_string "getCaseCount returned no number"
;;

let get_case_info url case =
  let info = ref "" in
  with_ws
    (endpoint url "getCaseInfo" [ "case", Int.to_string case ])
    (fun r _w ->
       Pipe.iter r ~f:(fun (fr : Frame.t) ->
         info := fr.payload;
         Deferred.unit))
  >>| fun _ -> !info
;;

(* The whole of a case: echo every message back with its own opcode, until the
   server closes. Text stays text and binary stays binary, which cases 1.x and
   6.x check; fastws has already reassembled fragments, so 9.x and 10.x echo as
   single frames, which the suite permits. *)
let run_case ?timeout url agent case =
  let url = endpoint url "runCase" [ "case", Int.to_string case; "agent", agent ] in
  let echo r w = Pipe.iter r ~f:(fun (fr : Frame.t) -> Pipe.write_if_open w fr) in
  match timeout with
  | None -> with_ws url echo
  | Some span ->
    (* A case that hangs must not stall the run: 6.4.x feed a payload byte at a
       time and 9.x push 16MiB, so the budget is generous, but unbounded it is
       not. *)
    Clock_ns.with_timeout span (with_ws url echo)
    >>| (function
     | `Result r -> r
     | `Timeout -> Or_error.error_string "case timed out")
;;

let update_reports url agent =
  with_ws
    (endpoint url "updateReports" [ "agent", agent ])
    (fun r _w -> Pipe.iter r ~f:(fun _ -> Deferred.unit))
;;

let main url agent from_ upto timeout () =
  Random.self_init ();
  get_case_count url
  >>=? fun count ->
  let last = Option.value_map upto ~default:count ~f:(Int.min count) in
  let first = Int.max 1 from_ in
  Log_async.app (fun m -> m "%d cases, running %d-%d" count first last)
  >>= fun () ->
  Deferred.List.iter
    ~how:`Sequential
    (List.range ~start:`inclusive ~stop:`inclusive first last)
    ~f:(fun case ->
      get_case_info url case
      >>= fun info ->
      run_case ?timeout url agent case
      >>= function
      | Ok () -> Log_async.app (fun m -> m "case %d/%d ok %s" case last info)
      | Error e ->
        (* Not a verdict: the suite decides. Several cases pass *by* killing
           the connection. *)
        Log_async.app (fun m -> m "case %d/%d ended: %a %s" case last Error.pp e info))
  >>= fun () ->
  Log_async.app (fun m -> m "writing reports") >>= fun () -> update_reports url agent
;;

let url_cmd = Command.Arg_type.create Uri.of_string

let () =
  Command.async_or_error
    ~summary:"Autobahn test suite client driver"
    (let open Command.Let_syntax in
     [%map_open
       let () = Logs_async_reporter.set_level_via_param []
       and url = anon ("url" %: url_cmd)
       and agent =
         flag "-agent" (optional_with_default "fastws" string) ~doc:"NAME agent name"
       and from_ = flag "-from" (optional_with_default 1 int) ~doc:"N first case index"
       and upto = flag "-to" (optional int) ~doc:"N last case index"
       and timeout =
         flag
           "-case-timeout"
           (optional_with_default (Time_ns.Span.of_int_sec 120) Time_ns.Span.arg_type)
           ~doc:"SPAN per-case timeout"
       in
       fun () ->
         Logs.set_reporter (Logs_async_reporter.reporter ());
         main url agent from_ upto (Some timeout) ()])
  |> Command_unix.run
;;
