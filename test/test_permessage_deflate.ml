open Core

module Deflate = Fastws_async__.Permessage_deflate

let params no_takeover =
  if no_takeover then [ "server_no_context_takeover", None ] else []
;;

let round_trip ~no_takeover messages =
  let compressor = Deflate.of_params `Server (params no_takeover) in
  let decompressor = Deflate.of_params `Client (params no_takeover) in
  Exn.protect
    ~f:(fun () ->
      List.iter messages ~f:(fun expected ->
        let compressed = Deflate.compress_exn compressor expected in
        let actual = Deflate.decompress_exn decompressor compressed in
        Alcotest.(check string) "round trip" expected actual))
    ~finally:(fun () ->
      Deflate.close compressor;
      Deflate.close decompressor)
;;

let messages =
  [ ""
  ; "short message"
  ; String.init 256 ~f:(fun i -> Char.of_int_exn (i land 0xff))
  ; String.concat (List.init 32_768 ~f:(fun i -> Int.to_string (i % 100)))
  ]
;;

let tests =
  [ Alcotest.test_case "context takeover" `Quick (fun () ->
      round_trip ~no_takeover:false messages)
  ; Alcotest.test_case "no context takeover" `Quick (fun () ->
      round_trip ~no_takeover:true messages)
  ]
;;

let () = Alcotest.run "permessage-deflate" [ "round trip", tests ]
