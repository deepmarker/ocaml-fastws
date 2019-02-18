open Async
open Alcotest
open Fastws

let () =
  Logs.set_level (Some Debug) ;
  Logs.set_reporter (Logs_async_reporter.reporter ())

let frames = [
  "empty text"        , textf "" ;
  "text with content" , textf "test" ;
  "empty continution" , createf Continuation ;
  "ping", createf Ping ;
  "pong", createf Pong ;
  "empty close", createf Close ;
  "close", closef Status.NormalClosure "bleh" ;
  "unfinished cont", { header = create ~final:false Continuation ; payload = None } ;
  "text with rsv", { header = create ~final:false ~rsv:7 Text ; payload = None } ;
  "empty binary", { header = create ~final:false Binary ; payload = None } ;
  "text 125", textf "%s" (Crypto.generate 125) ;
  "binary 125", binaryf "%s" (Crypto.generate 125) ;
  "text 126", create ~content:(Crypto.generate 126) Opcode.Text ;
  "binary 126", create ~content:(Crypto.generate 126) Opcode.Binary ;
  "binary 65536", create ~content:(Crypto.generate (1 lsl 16)) Opcode.Binary ;
]

let multiframes = [
  "double text", [create Opcode.Text ; create Opcode.Text] ;
  "text close", [create Opcode.Text ; create Opcode.Close] ;
  "close text", [create Opcode.Close ; create Opcode.Text] ;
  "double close", [create Opcode.Close ; create Opcode.Close] ;
]

let frame = testable pp equal

let filter_map f l =
  List.fold_right
    (fun e a -> match f e with None -> a | Some v -> v :: a) l []

let roundtrip ?mask descr frames () =
  let pp = Faraday.create 256 in
  List.iter (serialize ?mask pp) frames ;
  let buf = Faraday.serialize_to_bigstring pp in
  let len = Bigstringaf.length buf in
  Format.eprintf "buffer is %d bytes long@." len ;
  let rec inner acc consumed =
    match Angstrom.(Unbuffered.parse parser) with
    | Partial { continue ; committed  = _ } -> begin
        Format.eprintf "inner %d %d@." consumed (len - consumed) ;
        match continue buf ~off:consumed ~len:(len - consumed) Angstrom.Unbuffered.Complete with
        | Done (0, _) ->
          Format.eprintf "Done.@." ;
          List.rev acc
        | Done (c, vs) ->
          Format.eprintf "Done %d@." c ;
          inner (filter_map (fun x -> x) [vs]) (consumed + c)
        | _ -> failwith "must be done"
      end
    | _ -> failwith "should not happen" in
  let frames' = inner [] 0 in
  List.iter (fun fr -> Logs.debug (fun m -> m "%a" Fastws.pp fr)) frames' ;
  check int "roundtrip list size" (List.length frames) (List.length frames') ;
  List.iter2 (check frame descr) frames frames'

let connect () =
  let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" () in
  let frame = create ~content:"msg" Text in
  Fastws_async.connect url >>= begin fun (r, w) ->
    Pipe.write w frame >>= fun () ->
    Pipe.read r >>= function
    | `Eof -> failwith "did not receive echo"
    | `Ok fr when fr = frame -> begin
        (* let close_fr = close () in
         * Pipe.write w close_fr >>= fun () ->
         * Pipe.read r >>= function
         * | `Eof -> failwith "did not receive close echo"
         * | `Ok fr when fr = close_fr ->
         *   Pipe.close w ;
         *   Pipe.close_read r ; *)
        Deferred.unit
        (* | _ -> failwith "close frame has been altered" *)
      end
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
  List.map
    (fun (n, f) -> n, `Quick, roundtrip n f)
    (List.map (fun (s, f) -> s, [f]) frames)

let roundtrip_masked =
  List.map begin fun (n, f) ->
    n, `Quick, roundtrip ~mask:(Crypto.generate 4) n f
  end
    (List.map (fun (s, f) -> s, [f]) frames)

let roundtrip_unmasked_multi =
  List.map
    (fun (n, f) -> n, `Quick, roundtrip n f) multiframes

let roundtrip_masked_multi =
  List.map begin fun (n, f) ->
    n, `Quick, roundtrip ~mask:(Crypto.generate 4) n f
  end multiframes

let async = Alcotest_async.[
    test_case "connect" `Quick connect ;
    (* test_case "with_connection_ez" `Quick with_connection_ez ; *)
  ]

let () =
  Alcotest.run "fastws" [
    "roundtrip", roundtrip_unmasked ;
    "roundtrip_masked", roundtrip_masked ;
    "roundtrip_multi", roundtrip_unmasked_multi ;
    "roundtrip_masked_multi", roundtrip_masked_multi ;
    (* "async", async ; *)
  ]

