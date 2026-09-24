open Core
open Async
open Alcotest
open Fastws
open Fastws_async

let url = Uri.make ~scheme:"https" ~host:"echo.websocket.org" ~path:"echo" ()
let frame = testable Frame.pp Frame.equal

let connect_f r w =
  (* hello frame *)
  Pipe.read_exn r
  >>= fun _fr ->
  (* write my frame *)
  let msg = Frame.String.textf "msg" in
  Pipe.write_if_open w msg
  >>= fun () ->
  Pipe.read_exn r
  >>= fun msg' ->
  check frame "" msg msg';
  Deferred.unit
;;

let src = Logs.Src.create "fastws.async.raw"

let connect () =
  Async_uri.connect url
  >>= fun { r; w; _ } ->
  connect ~src url r w Fn.id Fn.id
  >>= function
  | Error e -> Error.raise (Raw.to_error e)
  | Ok { r; w } -> connect_f r w
;;

let of_frame { Frame.payload; _ } = payload
let to_frame msg = Frame.String.textf "%s" msg
let msg = "msg"

let connect_ez () =
  Async_uri.with_connection url (fun { r; w; _ } ->
    Fastws_async.Raw.to_or_error (Fastws_async.connect url r w of_frame to_frame)
    >>=? fun { r; w; _ } ->
    Pipe.read r
    >>= fun _hello_frame ->
    Pipe.write w msg
    >>= fun () ->
    Pipe.read r
    >>= fun res ->
    Pipe.close w;
    Pipe.close_read r;
    Deferred.all_unit [ Pipe.closed w; Pipe.closed r ]
    >>= fun () ->
    match res with
    | `Eof -> Deferred.Or_error.fail (Error.of_string "did not receive echo")
    | `Ok msg' ->
      check string "" msg msg';
      Deferred.Or_error.ok_unit)
;;

let with_connection_ez () =
  Async_uri.with_connection url (fun { r; w; _ } ->
    Fastws_async.with_connection url r w of_frame to_frame (fun r w ->
      Pipe.read r
      >>= fun _hello ->
      Pipe.write w msg
      >>= fun () ->
      Pipe.read r
      >>| function
      | `Eof -> failwith "did not receive echo"
      | `Ok msg' -> check string "" msg msg')
    |> Fastws_async.Raw.to_or_error)
;;

let runtest a b c =
  Alcotest_async.test_case a b (fun () -> Deferred.Or_error.ok_exn (c ()))
;;

let async =
  [ Alcotest_async.test_case "connect" `Quick connect
  ; runtest "connect_ez" `Quick connect_ez
  ; runtest "with_connection_ez" `Quick with_connection_ez
  ]
;;

let close_payload code reason =
  let payload = Bytes.create (2 + String.length reason) in
  Stdlib.Bytes.set_int16_be payload 0 code;
  Stdlib.Bytes.blit_string reason 0 payload 2 (String.length reason);
  Stdlib.Bytes.unsafe_to_string payload
;;

let close_callback () =
  Unix.pipe (Info.of_string "fastws close input")
  >>= fun (`Reader client_input, `Writer peer_output) ->
  Unix.pipe (Info.of_string "fastws close output")
  >>= fun (`Reader peer_input, `Writer client_output) ->
  let client_reader = Reader.create client_input in
  let client_writer = Writer.create client_output in
  let peer_writer = Writer.create peer_output in
  let peer_reader = Reader.create peer_input in
  let received = Ivar.create () in
  let { r; w } =
    Fastws_async.of_initialized
      ~on_close:(Ivar.fill_if_empty received)
      client_reader
      client_writer
      Httpun.Headers.empty
      Fn.id
      Fn.id
  in
  let payload = close_payload 4009 "subscription limit" in
  let frame =
    Frame.String.close ~status:(Status.Unknown 4009, Some "subscription limit") ()
  in
  let serializer = Faraday.create 32 in
  Header.serialize serializer frame.header;
  Faraday.write_string serializer payload;
  Faraday.close serializer;
  let wire_buf = Faraday.serialize_to_bigstring serializer in
  let wire = Bigstringaf.substring wire_buf ~off:0 ~len:(Bigstringaf.length wire_buf) in
  Writer.write peer_writer wire;
  Writer.flushed peer_writer
  >>= fun () ->
  Ivar.read received
  >>= fun { code; reason } ->
  check (option int) "code" (Some 4009) code;
  check string "reason" "subscription limit" reason;
  Pipe.close w;
  Pipe.close_read r;
  Deferred.all_unit
    [ Writer.close peer_writer
    ; Reader.close peer_reader
    ; Writer.close client_writer
    ; Reader.close client_reader
    ]
;;

let main () =
  Alcotest_async.run
    "fastws-async"
    [ "async", async
    ; "close", [ Alcotest_async.test_case "callback" `Quick close_callback ]
    ]
;;

let () =
  Logs.set_level (Some Debug);
  Logs.set_reporter (Logs_async_reporter.reporter ());
  don't_wait_for (main ());
  never_returns (Scheduler.go ())
;;
