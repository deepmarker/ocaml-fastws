open Core
open Async
open Alcotest
open Fastws
open Fastws_async
open Fastws_async.Raw

let url = Uri.make ~scheme:"http" ~host:"echo.websocket.org" ~path:"echo" ()
let frame = testable Frame.pp Frame.equal

let connect_f mv w =
  let msg = Frame.String.textf "msg" in
  write_frame_if_open w msg
  >>= fun () ->
  Mvar.take mv
  >>= fun {header; payload} ->
  write_frame_if_open w (Frame.Bigstring.close ())
  >>= fun () ->
  Mvar.take mv
  >>| fun _cl ->
  let msg' =
    {Frame.header; payload= Option.value ~default:(Bigstringaf.create 0) payload}
  in
  check frame "" msg msg'

let handle_incoming_frame mv x = Mvar.put mv x

let connect () =
  let mv = Mvar.create () in
  Async_uri.connect url
  >>= fun {r; w; _} ->
  Fastws_async.Raw.(to_or_error (connect url r w))
  >>=? fun (_exts, r, w) ->
  Deferred.all_unit [connect_f mv w; Pipe.iter r ~f:(handle_incoming_frame mv)]
  >>= fun () -> Deferred.Or_error.ok_unit

let of_frame {Frame.payload; _} = Bigstring.to_string payload
let to_frame msg = Frame.String.textf "%s" msg
let msg = "msg"

let connect_ez () =
  Async_uri.with_connection url (fun {r; w; _} ->
      Fastws_async.Raw.to_or_error
        (Fastws_async.connect url r w of_frame to_frame)
      >>=? fun {r; w; _} ->
      Pipe.write w msg
      >>= fun () ->
      Pipe.read r
      >>= fun res ->
      Pipe.close w ;
      Pipe.close_read r ;
      Deferred.all_unit [Pipe.closed w; Pipe.closed r]
      >>= fun () ->
      match res with
      | `Eof -> failwith "did not receive echo"
      | `Ok msg' ->
          check string "" msg msg' ;
          Deferred.Or_error.ok_unit )

let with_connection_ez () =
  Async_uri.with_connection url (fun {r; w; _} ->
      Fastws_async.with_connection url r w of_frame to_frame (fun r w ->
          Pipe.write w msg
          >>= fun () ->
          Pipe.read r
          >>| function
          | `Eof -> failwith "did not receive echo"
          | `Ok msg' -> check string "" msg msg' )
      |> Fastws_async.Raw.to_or_error )

let runtest a b c =
  Alcotest_async.test_case a b (fun () -> Deferred.Or_error.ok_exn (c ()))

let async =
  [ runtest "connect" `Quick connect; runtest "connect_ez" `Quick connect_ez;
    runtest "with_connection_ez" `Quick with_connection_ez ]

let main () = Alcotest.run "fastws-async" [("async", async)]

let () =
  main () ;
  never_returns (Scheduler.go ())
