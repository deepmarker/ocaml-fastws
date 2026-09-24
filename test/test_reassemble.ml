(* Fragment reassembly, and the control frames that arrive in the middle of
   it.

   RFC 6455 §5.4 lets a peer inject a control frame between the fragments of
   a message, and §5.5 lets that control frame carry up to 125 bytes. A
   close frame with a reason is both at once, and it is what Paradex sends:
   `{"reason":"inbound queue full"}` landing between fragments of a large
   binary frame used to reach an `assert false` here and take the worker
   down instead of reporting the close. *)

open Core
open Alcotest
open Fastws

let frame ?(final = true) ?(rsv = 0) opcode payload =
  { Frame.header = { Header.opcode; rsv; final; length = String.length payload; mask = None }
  ; payload
  }
;;

let feed frames = Fastws_async.For_testing.reassemble frames

let ok_some what = function
  | Ok (Some f) -> f
  | Ok None -> failf "%s: expected a frame, got a fragment" what
  | Error e -> failf "%s: %s" what (Error.to_string_hum e)
;;

let ok_none what = function
  | Ok None -> ()
  | Ok (Some _) -> failf "%s: expected a fragment to be absorbed" what
  | Error e -> failf "%s: %s" what (Error.to_string_hum e)
;;

let test_plain_fragmentation () =
  match feed [ frame ~final:false Binary "he"; frame Continuation "llo" ] with
  | [ a; b ] ->
    ok_none "first fragment" a;
    let f = ok_some "final fragment" b in
    check string "reassembled" "hello" f.payload;
    check bool "and marked final" true f.header.final
  | _ -> fail "expected two results"
;;

(* The bug. A close carrying a reason, mid-message. *)
let test_close_with_reason_mid_fragment () =
  let reason = "\003\232{\"reason\":\"inbound queue full\"}" in
  match
    feed [ frame ~final:false Binary "he"; frame Close reason; frame Continuation "llo" ]
  with
  | [ a; b; c ] ->
    ok_none "first fragment" a;
    let close = ok_some "the close" b in
    check bool "passed through as a close" true (Poly.equal close.header.opcode Close);
    check string "with its reason intact" reason close.payload;
    (* And the interrupted message still finishes: the control frame does
       not disturb what it interrupted. *)
    let f = ok_some "final fragment" c in
    check string "message still reassembles" "hello" f.payload
  | _ -> fail "expected three results"
;;

let test_ping_with_payload_mid_fragment () =
  match feed [ frame ~final:false Text "a"; frame Ping "hb"; frame Continuation "b" ] with
  | [ _; b; c ] ->
    let ping = ok_some "the ping" b in
    check string "payload kept" "hb" ping.payload;
    check string "message still reassembles" "ab" (ok_some "final" c).payload
  | _ -> fail "expected three results"
;;

let test_empty_control_mid_fragment () =
  match feed [ frame ~final:false Text "a"; frame Ping ""; frame Continuation "b" ] with
  | [ _; b; c ] ->
    check string "an empty ping still works" "" (ok_some "the ping" b).payload;
    check string "message still reassembles" "ab" (ok_some "final" c).payload
  | _ -> fail "expected three results"
;;

(* A peer that starts a second message before finishing the first is in
   violation; that is a statement about the peer, so it is an error rather
   than an assertion. *)
let test_interleaved_message_is_an_error () =
  match feed [ frame ~final:false Binary "a"; frame ~final:false Binary "b" ] with
  | [ _; Error e ] ->
    check bool "names the violation" true
      (String.is_substring (Error.to_string_hum e) ~substring:"interleaved")
  | [ _; Ok _ ] -> fail "interleaving should not be accepted"
  | _ -> fail "expected two results"
;;

let test_unfinished_continuation_is_an_error () =
  match feed [ frame ~final:false Binary "a"; frame Binary "b" ] with
  | [ _; Error _ ] -> ()
  | _ -> fail "a final data frame mid-message is a violation"
;;

(* RFC 6455 §5.2. RSV1 is the one reserved bit fastws can ever accept, and only
   on a connection that negotiated permessage-deflate. Autobahn 3.4 is the
   no-extension half of this: a text frame with RSV=4 on a bare connection has
   to fail it, not be handed to the application still compressed. *)
let check_hdr ~deflate f = Fastws_async.For_testing.check_hdr ~deflate f

let test_rsv1_needs_negotiation () =
  check bool "rsv1 without deflate is a violation" false
    (check_hdr ~deflate:false (frame ~rsv:4 Text "x"));
  check bool "rsv1 with deflate is a compressed message" true
    (check_hdr ~deflate:true (frame ~rsv:4 Text "x"));
  check bool "and on binary too" true
    (check_hdr ~deflate:true (frame ~rsv:4 Binary "x"))
;;

(* §7692 6.1: control frames are never compressed, so RSV1 on one is a
   violation even with the extension in play. *)
let test_rsv1_never_on_control () =
  List.iter [ Opcode.Close; Ping; Pong ] ~f:(fun opcode ->
    check bool
      (Format.asprintf "rsv1 on %a is a violation" Opcode.pp opcode)
      false
      (check_hdr ~deflate:true (frame ~rsv:4 opcode "")))
;;

let test_rsv2_and_rsv3_are_always_violations () =
  List.iter [ 1; 2; 3; 5; 6; 7 ] ~f:(fun rsv ->
    check bool (Printf.sprintf "rsv=%d without deflate" rsv) false
      (check_hdr ~deflate:false (frame ~rsv Text "x"));
    check bool (Printf.sprintf "rsv=%d with deflate" rsv) false
      (check_hdr ~deflate:true (frame ~rsv Text "x")))
;;

let test_plain_headers_pass () =
  check bool "no reserved bits, no extension" true
    (check_hdr ~deflate:false (frame Text "x"));
  check bool "no reserved bits, extension negotiated" true
    (check_hdr ~deflate:true (frame Text "x"));
  check bool "reserved opcodes are a violation" false
    (check_hdr ~deflate:false (frame (Opcode.Nonctrl 5) "x"))
;;

let () =
  Alcotest.run
    "fastws reassembly"
    [ ( "fragments"
      , [ test_case "a fragmented message reassembles" `Quick test_plain_fragmentation
        ; test_case "a close with a reason passes through" `Quick
            test_close_with_reason_mid_fragment
        ; test_case "so does a ping with a body" `Quick test_ping_with_payload_mid_fragment
        ; test_case "and an empty control frame" `Quick test_empty_control_mid_fragment
        ] )
    ; ( "violations"
      , [ test_case "interleaving is reported" `Quick test_interleaved_message_is_an_error
        ; test_case "an unfinished continuation is reported" `Quick
            test_unfinished_continuation_is_an_error
        ] )
    ; ( "reserved bits"
      , [ test_case "rsv1 requires permessage-deflate" `Quick test_rsv1_needs_negotiation
        ; test_case "rsv1 never rides a control frame" `Quick test_rsv1_never_on_control
        ; test_case "rsv2 and rsv3 are always violations" `Quick
            test_rsv2_and_rsv3_are_always_violations
        ; test_case "ordinary headers pass" `Quick test_plain_headers_pass
        ] )
    ]
;;
