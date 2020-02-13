open Core
open Async
open Alcotest
open Fastws
open Fastws_async_raw
open Fastws_async

let frames = [
  "empty text"        , textf "" ;
  "text with content" , textf "test" ;
  "empty continution" , createf Continuation "" ;
  "ping", createf Ping "" ;
  "pong", createf Pong "" ;
  "empty close", { header = create Close ; payload = None } ;
  "close", closef "bleh" ;
  "unfinished cont", { header = create ~final:false Continuation ; payload = None } ;
  "text with rsv", { header = create ~final:false ~rsv:7 Text ; payload = None } ;
  "empty binary", { header = create ~final:false Binary ; payload = None } ;
  "text 125", textf "%s" (Crypto.generate 125) ;
  "binary 125", binaryf "%s" (Crypto.generate 125) ;
  "text 126", textf "%s" (Crypto.generate 126) ;
  "binary 126", binaryf "%s" (Crypto.generate 126) ;
  "binary 65536", binaryf "%s" (Crypto.generate (1 lsl 16)) ;
]

let multiframes = [
  "double text", [textf "" ; textf ""] ;
  "text close", [textf "" ; closef ""] ;
  "close text", [closef "" ; textf ""] ;
  "double close", [closef "" ; closef ""] ;
]

let frame =
  testable pp_frame begin fun a b ->
    match a, b with
    | { header ; payload = None},
      { header = header' ; payload = None } ->
      Fastws.equal header header'
    | { header ; payload = Some p},
      { header = header' ; payload = Some p' } ->
      Fastws.equal header header' &&
      let open Bigstringaf in
      let len = length p in
      len = length p' && unsafe_memcmp p 0 p' 0 len = 0
    | _ -> false
  end

let roundtrip ?mask descr frames () =
  let pp = Faraday.create 256 in
  List.iter ~f:begin fun { header ; payload } ->
    Format.eprintf "Free bytes_in_buffer %d@." (Faraday.free_bytes_in_buffer pp);
    serialize pp { header with mask } ;
    match payload with
    | None -> ()
    | Some payload -> Faraday.write_bigstring pp payload
  end frames ;
  let buf = Faraday.serialize_to_bigstring pp in
  let len = Bigstringaf.length buf in
  Format.eprintf "buffer is %d bytes long@." len ;
  let rec inner acc pos =
    if pos = len then List.rev acc else begin
      Format.eprintf "parse %d@." pos ;
      match parse ~pos buf with
      | `More _ -> failwith "`More should not be returned"
      | `Ok (t, nb_read) ->
        match t.length with
        | 0 ->
          inner ({ header = t ; payload = None } :: acc) (pos + nb_read)
        | len ->
          Format.eprintf "matched %d@." len ;
          let payload = Bigstringaf.sub buf ~off:(pos + nb_read) ~len in
          inner ({ header = t ; payload = Some payload } :: acc)
            (pos + nb_read + len)
    end
  in
  let frames' = inner [] 0 in
  check int "roundtrip list size" (List.length frames) (List.length frames') ;
  List.iter2_exn ~f:begin fun f f' ->
    check frame descr { f with header = { f.header with mask } } f'
  end frames frames'

let connect_f mv w =
  let msg = text "msg" in
  write_frame w msg >>= fun () ->
  Mvar.take mv >>= fun header ->
  Mvar.take mv >>= fun payload ->
  write_frame w (close "") >>= fun () ->
  Mvar.take mv >>| fun _cl ->
  match header, payload with
  | Header header, Payload payload ->
    let msg' = { header ; payload = Some payload } in
    check frame "" msg msg'
  | _ -> failwith "wrong message sequence"

let handle_incoming_frame mv = function
  | Fastws_async_raw.Header _ as fr ->
    Mvar.put mv fr
  | Payload pld ->
    Mvar.put mv (Payload (Bigstringaf.(copy pld ~off:0 ~len:(length pld))))

let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" ~path:"echo" ()

let connect () =
  let mv = Mvar.create () in
  Fastws_async_raw.connect url >>= fun (r, w) ->
    Deferred.all_unit [
      connect_f mv w ;
      Pipe.iter r ~f:(handle_incoming_frame mv) ;
    ]

let connect_ez () =
  Fastws_async.connect ~of_string:Fn.id ~to_string:Fn.id url >>= fun { r; w; _ } ->
    let msg = "msg" in
    Pipe.write w msg >>= fun () ->
    Pipe.read r >>= fun res ->
    Pipe.close w ;
    Pipe.close_read r ;
    Deferred.all_unit [Pipe.closed w; Pipe.closed r] >>| fun () ->
    match res with
    | `Eof -> failwith "did not receive echo"
    | `Ok msg' -> check string "" msg msg'

let with_connection_ez () =
  let msg = "msg" in
  Fastws_async.with_connection ~of_string:Fn.id ~to_string:Fn.id url begin fun r w ->
    Pipe.write w msg >>= fun () ->
    Pipe.read r >>| function
    | `Eof -> failwith "did not receive echo"
    | `Ok msg' -> check string "" msg msg'
  end

open Alcotest_async

let roundtrip_unmasked =
  List.map
    ~f:(fun (n, f) -> test_case_sync n `Quick (roundtrip n f))
    (List.map ~f:(fun (s, f) -> s, [f]) frames)

let roundtrip_masked =
  List.map ~f:begin fun (n, f) ->
    test_case_sync n `Quick (roundtrip ~mask:(Crypto.generate 4) n f)
  end
    (List.map ~f:(fun (s, f) -> s, [f]) frames)

let roundtrip_unmasked_multi =
  List.map
    ~f:(fun (n, f) -> test_case_sync n `Quick (roundtrip n f)) multiframes

let roundtrip_masked_multi =
  List.map ~f:begin fun (n, f) ->
    test_case_sync n `Quick (roundtrip ~mask:(Crypto.generate 4) n f)
  end multiframes

let async = Alcotest_async.[
    test_case "connect" `Quick connect ;
    test_case "connect_ez" `Quick connect_ez ;
    test_case "with_connection_ez" `Quick with_connection_ez ;
  ]

let main () =
  run "fastws" [
    "roundtrip", roundtrip_unmasked ;
    "roundtrip_masked", roundtrip_masked ;
    "roundtrip_multi", roundtrip_unmasked_multi ;
    "roundtrip_masked_multi", roundtrip_masked_multi ;
    "async", async ;
  ]

let () =
  don't_wait_for (main ()) ;
  never_returns (Scheduler.go ())
