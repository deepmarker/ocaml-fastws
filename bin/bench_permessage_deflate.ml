open Core

module Deflate = Fastws_async__.Permessage_deflate

let payload size =
  let event =
    {|{"stream":"btcusdt@bookTicker","data":{"e":"bookTicker","u":400900217,"s":"BTCUSDT","b":"62891.10","B":"12.345","a":"62891.20","A":"8.765"}}|}
  in
  String.init size ~f:(fun i -> event.[i % String.length event])
;;

let compressed_messages ~count ~size =
  let compressor =
    Deflate.of_params `Server [ "server_no_context_takeover", None ]
  in
  Exn.protect
    ~f:(fun () ->
      let plain = payload size in
      Array.init count ~f:(fun _ -> Deflate.compress_exn compressor plain), plain)
    ~finally:(fun () -> Deflate.close compressor)
;;

let allocated_words before after =
  Gc.Stat.minor_words after
  +. Gc.Stat.major_words after
  -. Gc.Stat.minor_words before
  -. Gc.Stat.major_words before
;;

let bench ~iterations ~size =
  let messages, expected = compressed_messages ~count:64 ~size in
  let decompressor =
    Deflate.of_params `Client [ "server_no_context_takeover", None ]
  in
  Exn.protect
    ~f:(fun () ->
      Gc.compact ();
      let before = Gc.quick_stat () in
      let started = Time_ns.now () in
      for i = 0 to iterations - 1 do
        let actual = Deflate.decompress_exn decompressor messages.(i land 63) in
        if not (String.equal actual expected) then failwith "decompression mismatch"
      done;
      let elapsed = Time_ns.diff (Time_ns.now ()) started in
      let after = Gc.quick_stat () in
      let ns = Time_ns.Span.to_ns elapsed /. Float.of_int iterations in
      let words = allocated_words before after /. Float.of_int iterations in
      printf "%6d bytes: %9.1f ns/message, %9.1f words/message\n%!" size ns words)
    ~finally:(fun () -> Deflate.close decompressor)
;;

let command =
  Command.basic
    ~summary:"Benchmark WebSocket permessage-deflate decompression"
    (let open Command.Let_syntax in
     let%map_open iterations =
       flag "-iterations" (optional_with_default 100_000 int) ~doc:"N iterations"
     in
     fun () -> List.iter [ 256; 1024; 4096; 16384 ] ~f:(fun size -> bench ~iterations ~size))
;;

let () = Command_unix.run command
