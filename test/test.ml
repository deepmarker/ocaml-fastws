open Async
open Alcotest_async

let () =
  Logs.set_level (Some Debug) ;
  Logs.set_reporter (Logs_async_reporter.reporter ())

let test_connection () =
  let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" () in
  Fastws_async.with_connection_ez url ~f:begin fun r w ->
    Pipe.write w "msg" >>= fun () ->
    Pipe.read r >>= function
    | `Eof -> failwith "did not receive echo"
    | `Ok "msg" -> Deferred.unit
    | `Ok _ -> failwith "message has been altered"
  end

let basic = [
  test_case "test_connection" `Quick test_connection ;
]

let () =
  Alcotest.run "fastws" [
    "basic", basic ;
  ]

