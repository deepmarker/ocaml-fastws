open Fastws
open Alcotest

let frames =
  let open Frame.String in
  [
    ("empty text", textf "");
    ("text with content", textf "test");
    ("empty continution", createf Continuation "");
    ("ping", createf Ping "");
    ("pong", createf Pong "");
    ("empty close", { header = Header.create Close; payload = None });
    ("close", closef "bleh");
    ( "unfinished cont",
      { header = Header.create ~final:false Continuation; payload = None } );
    ( "text with rsv",
      { header = Header.create ~final:false ~rsv:7 Text; payload = None } );
    ( "empty binary",
      { header = Header.create ~final:false Binary; payload = None } );
    ("text 125", textf "%s" (Crypto.generate 125));
    ("binary 125", binaryf "%s" (Crypto.generate 125));
    ("text 126", textf "%s" (Crypto.generate 126));
    ("binary 126", binaryf "%s" (Crypto.generate 126));
    ("binary 65536", binaryf "%s" (Crypto.generate (1 lsl 16)));
  ]

let multiframes =
  let open Frame.String in
  [
    ("double text", [ textf ""; textf "" ]);
    ("text close", [ textf ""; closef "" ]);
    ("close text", [ closef ""; textf "" ]);
    ("double close", [ closef ""; closef "" ]);
  ]

let frame = testable Frame.pp Frame.equal

let roundtrip ?mask descr frames () =
  let pp = Faraday.create 256 in
  List.iter
    (fun { Frame.header; payload } ->
      Format.eprintf "Free bytes_in_buffer %d@."
        (Faraday.free_bytes_in_buffer pp);
      Header.serialize pp { header with mask };
      match payload with
      | None -> ()
      | Some payload -> Faraday.write_bigstring pp payload)
    frames;
  let buf = Faraday.serialize_to_bigstring pp in
  let len = Bigstringaf.length buf in
  Format.eprintf "buffer is %d bytes long@." len;
  let rec inner acc pos =
    if pos = len then List.rev acc
    else (
      Format.eprintf "parse %d@." pos;
      match Header.parse ~pos buf with
      | `Need _ -> failwith "`Need should not be returned"
      | `Ok (t, nb_read) -> (
          match t.length with
          | 0 ->
              inner ({ Frame.header = t; payload = None } :: acc) (pos + nb_read)
          | len ->
              Format.eprintf "matched %d@." len;
              let payload = Bigstringaf.sub buf ~off:(pos + nb_read) ~len in
              inner
                ({ header = t; payload = Some payload } :: acc)
                (pos + nb_read + len) ) )
  in
  let frames' = inner [] 0 in
  check int "roundtrip list size" (List.length frames) (List.length frames');
  List.iter2
    (fun f f' ->
      check frame descr { f with header = { f.Frame.header with mask } } f')
    frames frames'

let roundtrip_unmasked =
  List.map
    (fun (n, f) -> test_case n `Quick (roundtrip n f))
    (List.map (fun (s, f) -> (s, [ f ])) frames)

let roundtrip_masked =
  List.map
    (fun (n, f) -> test_case n `Quick (roundtrip ~mask:(Crypto.generate 4) n f))
    (List.map (fun (s, f) -> (s, [ f ])) frames)

let roundtrip_unmasked_multi =
  List.map (fun (n, f) -> test_case n `Quick (roundtrip n f)) multiframes

let roundtrip_masked_multi =
  List.map
    (fun (n, f) -> test_case n `Quick (roundtrip ~mask:(Crypto.generate 4) n f))
    multiframes

let () =
  run "fastws"
    [
      ("roundtrip", roundtrip_unmasked);
      ("roundtrip_masked", roundtrip_masked);
      ("roundtrip_multi", roundtrip_unmasked_multi);
      ("roundtrip_masked_multi", roundtrip_masked_multi);
    ]
