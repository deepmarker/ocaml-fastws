open Core

let src = Logs.Src.create "permessage.deflate"

module Lo = (val Logs.src_log src : Logs.LOG)

external inflate_reset : Zlib.stream -> unit = "fastws_inflate_reset"
external deflate_reset : Zlib.stream -> unit = "fastws_deflate_reset"

type t =
  { inflate_stream : Zlib.stream
  ; deflate_stream : Zlib.stream
  ; mutable output_buffer : Bytes.t
  ; mutable output_pos : int
  ; input_buffer : Buffer.t
  ; input_chunk : Bytes.t
  ; client_no_takeover : bool
  ; server_no_takeover : bool
  ; role : [ `Client | `Server ]
  }

let create ?(client_no_takeover = false) ?(server_no_takeover = false) role =
  { inflate_stream = Zlib.inflate_init false
  ; deflate_stream = Zlib.deflate_init 6 false
  ; (* level 6, no zlib header *)
    output_buffer = Bytes.create (16 * 1024)
  ; output_pos = 0
  ; input_buffer = Buffer.create 4096
  ; input_chunk = Bytes.create 4096
  ; client_no_takeover
  ; server_no_takeover
  ; role
  }
;;

let of_params role params =
  let client_no_takeover =
    List.Assoc.mem params ~equal:String.Caseless.equal "client_no_context_takeover"
  in
  let server_no_takeover =
    List.Assoc.mem params ~equal:String.Caseless.equal "server_no_context_takeover"
  in
  Lo.debug (fun m ->
    m
      "initializing context: client_no_takeover: %b, server_no_takeover: %b"
      client_no_takeover
      server_no_takeover);
  create ~client_no_takeover ~server_no_takeover role
;;

let should_reset_inflate t =
  match t.role with
  | `Client -> t.server_no_takeover
  | `Server -> t.client_no_takeover
;;

let should_reset_deflate t =
  match t.role with
  | `Client -> t.client_no_takeover
  | `Server -> t.server_no_takeover
;;

let close_inflate_stream stream =
  try Zlib.inflate_end stream with
  | Zlib.Error ("Zlib.inflateEnd", msg) ->
    Lo.debug (fun m -> m "Ignoring inflate cleanup error: %s" msg)
;;

let close_deflate_stream stream =
  try Zlib.deflate_end stream with
  | Zlib.Error ("Zlib.deflateEnd", msg) ->
    Lo.debug (fun m -> m "Ignoring deflate cleanup error: %s" msg)
;;

let reset_inflate t =
  if should_reset_inflate t then inflate_reset t.inflate_stream
;;

let reset_deflate t =
  if should_reset_deflate t then deflate_reset t.deflate_stream
;;

let close t =
  close_inflate_stream t.inflate_stream;
  close_deflate_stream t.deflate_stream
;;

let ensure_output_capacity t =
  if t.output_pos = Bytes.length t.output_buffer
  then (
    let next = Bytes.create (2 * Bytes.length t.output_buffer) in
    Bytes.blit
      ~src:t.output_buffer
      ~src_pos:0
      ~dst:next
      ~dst_pos:0
      ~len:t.output_pos;
    t.output_buffer <- next)
;;

let inflate_segment t input =
  let input_len = String.length input in
  let rec loop pos =
    ensure_output_capacity t;
    let remaining = input_len - pos in
    let output_available = Bytes.length t.output_buffer - t.output_pos in
    let _finished, used_in, used_out =
      Zlib.inflate_string
        t.inflate_stream
        input
        pos
        remaining
        t.output_buffer
        t.output_pos
        output_available
        Zlib.Z_SYNC_FLUSH
    in
    t.output_pos <- t.output_pos + used_out;
    let pos = pos + used_in in
    if pos < input_len || used_out = output_available
    then (
      if used_in = 0 && used_out = 0 then failwith "Decompression stalled";
      loop pos)
  in
  loop 0
;;

let decompress_exn t compressed =
  t.output_pos <- 0;
  inflate_segment t compressed;
  inflate_segment t "\x00\x00\xff\xff";
  reset_inflate t;
  Stdlib.Bytes.sub_string t.output_buffer 0 t.output_pos
;;

let compress_exn t data =
  Buffer.clear t.input_buffer;
  let input_len = String.length data in
  let rec flush_loop () =
    let _finished, _, used_out =
      Zlib.deflate
        t.deflate_stream
        (Bytes.create 0)
        0
        0
        t.input_chunk
        0
        (Bytes.length t.input_chunk)
        Zlib.Z_SYNC_FLUSH
    in
    Buffer.add_subbytes t.input_buffer t.input_chunk ~pos:0 ~len:used_out;
    if used_out > 0 then flush_loop ()
  in
  let finish () =
    flush_loop ();
    (* Remove trailing 0x00 0x00 0xff 0xff *)
    let compressed = Buffer.contents t.input_buffer in
    let len = String.length compressed in
    reset_deflate t;
    if len >= 4 && String.(suffix compressed 4 = "\x00\x00\xff\xff")
    then String.sub compressed ~pos:0 ~len:(len - 4)
    else compressed
  in
  let rec continue pos =
    let remaining = input_len - pos in
    let _finished, used_in, used_out =
      Zlib.deflate
        t.deflate_stream
        (Bytes.unsafe_of_string_promise_no_mutation data)
        pos
        remaining
        t.input_chunk
        0
        (Bytes.length t.input_chunk)
        Zlib.Z_NO_FLUSH
    in
    Buffer.add_subbytes t.input_buffer t.input_chunk ~pos:0 ~len:used_out;
    loop (pos + used_in)
  and loop pos = if pos >= input_len then finish () else continue pos in
  loop 0
;;
