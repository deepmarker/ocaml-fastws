(* The WebSocket server side, checked against fastws's own client where the
   handshake has to work end to end, and against raw bytes where what matters
   is exactly what the server says. *)

open Core
open Async
open Alcotest
open Alcotest_async

let text = Fastws.Frame.String.textf "%s"
let payload (f : Fastws.Frame.t) = f.payload

(* An echo server that records what it was asked for. *)
let echo_server ?protocol () =
  let targets = ref [] in
  let closed = Ivar.create () in
  Fastws_async.Server.serve
    ?protocol
    Tcp.Where_to_listen.of_port_chosen_by_os
    payload
    text
    (fun _addr request conn ->
       targets := request.target :: !targets;
       Pipe.transfer_id conn.r conn.w >>| fun () -> Ivar.fill_if_empty closed ())
  >>| fun server -> server, targets, closed
;;

let url server path =
  Uri.make ~scheme:"ws" ~host:"127.0.0.1" ~port:(Tcp.Server.listening_on server) ~path ()
;;

let echo_round_trip () =
  echo_server ()
  >>= fun (server, targets, closed) ->
  Fastws_async.connect_or_error payload text (url server "/ws/v5/public")
  >>| Or_error.ok_exn
  >>= fun conn ->
  Pipe.write conn.w "hello"
  >>= fun () ->
  Pipe.read conn.r
  >>= fun reply ->
  check
    (option string)
    "echoed"
    (Some "hello")
    (match reply with
     | `Ok s -> Some s
     | `Eof -> None);
  check (list string) "the server saw the target" [ "/ws/v5/public" ] !targets;
  Pipe.close conn.w;
  Clock_ns.with_timeout (Time_ns.Span.of_int_sec 5) (Ivar.read closed)
  >>= fun r ->
  check
    bool
    "a client close ends the server's handler"
    true
    (match r with
     | `Result () -> true
     | `Timeout -> false);
  Tcp.Server.close server
;;

let many_frames () =
  echo_server ()
  >>= fun (server, _, _) ->
  Fastws_async.connect_or_error payload text (url server "/")
  >>| Or_error.ok_exn
  >>= fun conn ->
  let n = 1_000 in
  let sent = List.init n ~f:(fun i -> String.make (i % 300) 'x' ^ Int.to_string i) in
  Deferred.List.iter sent ~how:`Sequential ~f:(Pipe.write conn.w)
  >>= fun () ->
  Pipe.read_exactly conn.r ~num_values:n
  >>= fun got ->
  let got =
    match got with
    | `Exactly q -> Queue.to_list q
    | `Fewer q -> Queue.to_list q
    | `Eof -> []
  in
  check (list string) "every frame, in order" sent got;
  Pipe.close conn.w;
  Tcp.Server.close server
;;

let subprotocol () =
  echo_server ~protocol:(List.find ~f:(String.equal "v2")) ()
  >>= fun (server, _, _) ->
  Fastws_async.connect_or_error ~protocols:[ "v1"; "v2" ] payload text (url server "/")
  >>| Or_error.ok_exn
  >>= fun conn ->
  Pipe.write conn.w "ok"
  >>= fun () ->
  Pipe.read conn.r
  >>= fun reply ->
  check
    bool
    "a negotiated connection works"
    true
    (match reply with
     | `Ok "ok" -> true
     | _ -> false);
  Pipe.close conn.w;
  Tcp.Server.close server
;;

(* What the server writes in answer to a raw request, up to the blank line. *)
let raw_exchange server request =
  Tcp.connect
    (Tcp.Where_to_connect.of_host_and_port
       (Host_and_port.create ~host:"127.0.0.1" ~port:(Tcp.Server.listening_on server)))
  >>= fun (_, r, w) ->
  Writer.write w request;
  let rec head acc =
    Reader.read_line r
    >>= function
    | `Ok "" | `Eof -> return (List.rev acc)
    | `Ok l -> head (l :: acc)
  in
  head [] >>= fun lines -> Writer.close w >>| fun () -> lines
;;

let upgrade ?(version = "13") ?(key = "dGhlIHNhbXBsZSBub25jZQ==") ?(extra = "") () =
  sprintf
    "GET /chat HTTP/1.1\r\n\
     Host: server.example.com\r\n\
     Upgrade: websocket\r\n\
     Connection: keep-alive, Upgrade\r\n\
     Sec-WebSocket-Key: %s\r\n\
     Sec-WebSocket-Version: %s\r\n\
     %s\r\n"
    key
    version
    extra
;;

let has lines l = List.mem lines l ~equal:String.equal

(* RFC 6455 section 1.3's own example: this key must produce this proof. *)
let rfc_accept_proof () =
  echo_server ()
  >>= fun (server, _, _) ->
  raw_exchange server (upgrade ())
  >>= fun lines ->
  check bool "101" true (has lines "HTTP/1.1 101 Switching Protocols");
  check
    bool
    "the RFC's accept proof"
    true
    (has lines "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=");
  Tcp.Server.close server
;;

let refusals () =
  echo_server ~protocol:List.hd ()
  >>= fun (server, _, _) ->
  raw_exchange server "GET / HTTP/1.1\r\nHost: x\r\n\r\n"
  >>= fun lines ->
  check bool "a plain GET is a 400" true (has lines "HTTP/1.1 400 Bad Request");
  raw_exchange server (upgrade ~version:"12" ())
  >>= fun lines ->
  check bool "an old version is a 426" true (has lines "HTTP/1.1 426 Upgrade Required");
  check bool "naming the one supported" true (has lines "Sec-WebSocket-Version: 13");
  raw_exchange server (upgrade ~key:"c2hvcnQ=" ())
  >>= fun lines ->
  check bool "a short key is a 400" true (has lines "HTTP/1.1 400 Bad Request");
  raw_exchange server (upgrade ~extra:"Sec-WebSocket-Protocol: chat, superchat\r\n" ())
  >>= fun lines ->
  check
    bool
    "the chosen subprotocol is announced"
    true
    (has lines "Sec-WebSocket-Protocol: chat");
  Tcp.Server.close server
;;

(* A client's ping carries its masking key; the pong answering it must not:
   a server's frames are never masked, and a strict client closes on one that
   is (python websockets did, with 1002). Bytes, since fastws's own client
   does not check. *)
let pong_is_unmasked () =
  echo_server ()
  >>= fun (server, _, _) ->
  Tcp.connect
    (Tcp.Where_to_connect.of_host_and_port
       (Host_and_port.create ~host:"127.0.0.1" ~port:(Tcp.Server.listening_on server)))
  >>= fun (_, r, w) ->
  Writer.write w (upgrade ());
  let rec head () =
    Reader.read_line r
    >>= function
    | `Ok "" | `Eof -> Deferred.unit
    | `Ok _ -> head ()
  in
  head ()
  >>= fun () ->
  (* FIN + ping, masked, payload "hi" under key 01 02 03 04. *)
  let key = "\x01\x02\x03\x04" in
  let masked =
    String.mapi "hi" ~f:(fun i c ->
      Char.of_int_exn (Char.to_int c lxor Char.to_int key.[i % 4]))
  in
  Writer.write
    w
    (String.of_char_list [ '\x89'; Char.of_int_exn (0x80 lor 2) ] ^ key ^ masked);
  let buf = Bytes.create 4 in
  Reader.really_read r buf
  >>= fun result ->
  check
    bool
    "a full pong frame"
    true
    (match result with
     | `Ok -> true
     | `Eof _ -> false);
  check int "it is a pong" 0x8a (Char.to_int (Bytes.get buf 0));
  check int "unmasked" 0 (Char.to_int (Bytes.get buf 1) land 0x80);
  check string "echoing the ping's payload" "hi" (Bytes.To_string.sub buf ~pos:2 ~len:2);
  Writer.close w >>= fun () -> Tcp.Server.close server
;;

let () =
  don't_wait_for
    (Alcotest_async.run
       "fastws_server"
       [ ( "server"
         , [ test_case "echo round trip" `Quick echo_round_trip
           ; test_case "many frames" `Quick many_frames
           ; test_case "subprotocol" `Quick subprotocol
           ; test_case "RFC accept proof" `Quick rfc_accept_proof
           ; test_case "refusals" `Quick refusals
           ; test_case "pong is unmasked" `Quick pong_is_unmasked
           ] )
       ]);
  never_returns (Scheduler.go ())
;;
