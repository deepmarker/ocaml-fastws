open Async
open Alcotest
(* open Alcotest_async *)
open Fastws

let () =
  Logs.set_level (Some Debug) ;
  Logs.set_reporter (Logs_async_reporter.reporter ())

let parse =
  Angstrom.parse_string Fastws.parser

let frames = [
  "empty text"        , create Opcode.Text ;
  "text with content" , create ~content:"test" Opcode.Text ;
  "empty continution" , create Opcode.Continuation ;
  "ping", create Opcode.Ping ;
  "pong", create Opcode.Pong ;
  "close", close ~msg:(Status.NormalClosure, "bleh") () ;
  "unfinished cont", create ~final:false Opcode.Continuation ;
  "text with rsv", create ~final:false ~rsv:7 Opcode.Text ;
  "empty binary", create ~final:false Opcode.Binary ;
  "long binary", create ~content:(Crypto.generate 126) Opcode.Binary ;
  (* "very long binary", create ~content:(Crypto.generate (1 lsl 16)) Opcode.Binary ; *)
]

let frame = testable pp equal

let roundtrip ?mask descr fr () =
  let pp = Faraday.create 128 in
  serialize ?mask pp fr ;
  let buf = Faraday.serialize_to_bigstring pp in
  match Angstrom.parse_bigstring parser buf with
  | Error msg -> fail msg
  | Ok fr'-> check frame descr fr fr'

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

let roundtrip_unmasked =
  List.map (fun (n, f) -> n, `Quick, roundtrip n f) frames

let roundtrip_masked =
  List.map begin fun (n, f) ->
    n, `Quick, roundtrip ~mask:(Crypto.generate 4) n f
  end frames

let async = [
  (* test_case "connect" `Quick connect ; *)
  (* test_case "with_connection_ez" `Quick with_connection_ez ; *)
]

let () =
  Alcotest.run "fastws" [
    "roundtrip", roundtrip_unmasked ;
    "roundtrip_masked", roundtrip_masked ;
    "async", async ;
  ]

