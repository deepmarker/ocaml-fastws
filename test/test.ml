open Async
open Alcotest_async

let () =
  Logs.set_level (Some Debug) ;
  Logs.set_reporter (Logs_async_reporter.reporter ())

let connect () =
  let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" () in
  let frame = Fastws.create ~content:"msg" Text in
  Fastws_async.connect url >>= begin fun (r, w) ->
    Pipe.write w frame >>= fun () ->
    Pipe.read r >>= function
    | `Eof -> failwith "did not receive echo"
    | `Ok fr when fr = frame -> Deferred.unit
    | `Ok _ -> failwith "message has been altered"
  end

let with_connection_ez () =
  let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" () in
  Fastws_async.with_connection_ez url ~f:begin fun r w ->
    Pipe.write w "msg" >>= fun () ->
    Pipe.read r >>= function
    | `Eof -> failwith "did not receive echo"
    | `Ok "msg" -> Deferred.unit
    | `Ok _ -> failwith "message has been altered"
  end

let basic = [
  test_case "connect" `Quick connect ;
  (* test_case "with_connection_ez" `Quick with_connection_ez ; *)
]

let () =
  Alcotest.run "fastws" [
    "basic", basic ;
  ]

