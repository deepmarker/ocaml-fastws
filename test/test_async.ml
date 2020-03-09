open Core
open Async
open Alcotest
open Alcotest_async
open Fastws
open Fastws_async
open Fastws_async_raw

let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" ~path:"echo" ()

let frame = testable Frame.pp Frame.equal

let connect_f mv w =
  let msg = Frame.text "msg" in
  write_frame w msg >>= fun () ->
  Mvar.take mv >>= fun header ->
  Mvar.take mv >>= fun payload ->
  write_frame w (Frame.close "") >>= fun () ->
  Mvar.take mv >>| fun _cl ->
  match (header, payload) with
  | Header header, Payload payload ->
      let msg' = { Frame.header; payload = Some payload } in
      check frame "" msg msg'
  | _ -> failwith "wrong message sequence"

let handle_incoming_frame mv = function
  | Fastws_async_raw.Header _ as fr -> Mvar.put mv fr
  | Payload pld ->
      Mvar.put mv (Payload Bigstringaf.(copy pld ~off:0 ~len:(length pld)))

let connect () =
  let mv = Mvar.create () in
  Fastws_async_raw.connect url >>= fun (r, w) ->
  Deferred.all_unit
    [ connect_f mv w; Pipe.iter r ~f:(handle_incoming_frame mv) ]

let connect_ez () =
  Fastws_async.connect ~of_string:Fn.id ~to_string:Fn.id url
  >>= fun { r; w; _ } ->
  let msg = "msg" in
  Pipe.write w msg >>= fun () ->
  Pipe.read r >>= fun res ->
  Pipe.close w;
  Pipe.close_read r;
  Deferred.all_unit [ Pipe.closed w; Pipe.closed r ] >>| fun () ->
  match res with
  | `Eof -> failwith "did not receive echo"
  | `Ok msg' -> check string "" msg msg'

let with_connection_ez () =
  let msg = "msg" in
  Fastws_async.with_connection ~of_string:Fn.id ~to_string:Fn.id url (fun r w ->
      Pipe.write w msg >>= fun () ->
      Pipe.read r >>| function
      | `Eof -> failwith "did not receive echo"
      | `Ok msg' -> check string "" msg msg')

let async =
  [
    test_case "connect" `Quick connect;
    test_case "connect_ez" `Quick connect_ez;
    test_case "with_connection_ez" `Quick with_connection_ez;
  ]

let main () = run "fastws-async" [ ("async", async) ]

let () =
  don't_wait_for (main ());
  never_returns (Scheduler.go ())
