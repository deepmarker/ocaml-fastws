(*---------------------------------------------------------------------------
  Copyright (c) 2020 DeepMarker. All rights reserved.
  Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
module Time_ns = Time_ns_unix
open Fastws
open Fastws_async_raw

let src = Logs.Src.create "fastws.async"

module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let empty_payload = ""

type st =
  { buf : Buffer.t
  ; mutable header : Header.t option
  ; mutable conn_state : [ `Open | `Closing | `Closed ]
  ; on_pong : Time_ns.Span.t option -> unit
  ; permessage_deflate : bool
  ; zs : Zlib.stream
  }

let create_st ?(permessage_deflate = false) ?(on_pong = Fn.ignore) () =
  { buf = Buffer.create 4096
  ; header = None
  ; conn_state = `Open
  ; on_pong
  ; permessage_deflate
  ; zs = Zlib.inflate_init false
  }
;;

let close_st { zs; _ } = Zlib.inflate_end zs
let must_decompress (st : st) (h : Header.t) = st.permessage_deflate && h.rsv = 4
let buffer = Buffer.create 4096

let uncompress zs refill flush =
  let buffer_size = 1024 in
  let open Zlib in
  let inbuf = Bytes.create buffer_size in
  let outbuf = Bytes.create buffer_size in
  let rec uncompr inpos inavail =
    if inavail = 0
    then (
      let incount = refill inbuf in
      if incount = 0 then uncompr_finish true else uncompr 0 incount)
    else (
      let finished, used_in, used_out =
        inflate zs inbuf inpos inavail outbuf 0 buffer_size Z_SYNC_FLUSH
      in
      flush outbuf used_out;
      if not finished then uncompr (inpos + used_in) (inavail - used_in))
  and uncompr_finish first_finish =
    let dummy_len =
      if first_finish
      then (
        Bytes.set inbuf 0 '\x00';
        Bytes.set inbuf 1 '\x00';
        Bytes.set inbuf 2 '\xff';
        Bytes.set inbuf 3 '\xff';
        4)
      else 0
    in
    let _finished, _, used_out =
      inflate zs inbuf 0 dummy_len outbuf 0 buffer_size Z_SYNC_FLUSH
    in
    flush outbuf used_out
  in
  uncompr 0 0
;;

let decompress inflate payload =
  let payload_len = String.length payload in
  let pos = ref 0 in
  let refill buf =
    let inlen = Bytes.length buf in
    let len = min inlen (payload_len - !pos) in
    Bytes.From_string.blit ~src:payload ~dst:buf ~src_pos:!pos ~dst_pos:0 ~len;
    pos := !pos + len;
    len
  in
  let flush buf len = Buffer.add_subbytes buffer buf ~pos:0 ~len in
  Buffer.clear buffer;
  uncompress inflate refill flush;
  Buffer.contents buffer
;;

let reassemble st (t : Fastws_async_raw.t) =
  match t, st.header with
  (* Erroneous cases *)
  | { header = { opcode; final = false; _ }; _ }, _ when Opcode.is_control opcode ->
    Format.kasprintf Or_error.error_string "fragmented control frame"
  | { header = { opcode; final = true; _ }; _ }, Some _
    when not Opcode.(is_control opcode || is_continuation opcode) ->
    Format.kasprintf Or_error.error_string "unfinished continuation"
  | { header = { opcode = Continuation; _ }; _ }, None ->
    Format.kasprintf Or_error.error_string "orphan continuation frame"
  (* Non-segmented frame *)
  | { header = { final = true; _ } as h; payload }, None ->
    (match payload with
     | None -> Ok (`Frame { Frame.header = h; payload = empty_payload })
     | Some payload when must_decompress st h ->
       let payload = decompress st.zs payload in
       let header = { h with length = String.length payload } in
       Ok (`Frame { Frame.header; payload })
     | Some payload -> Ok (`Frame { Frame.header = h; payload }))
  (* Non final first frame *)
  | { header = { final = false; _ } as h; payload }, None ->
    st.header <- Some h;
    Buffer.clear st.buf;
    Option.iter payload ~f:(Buffer.add_string st.buf);
    Ok `Continue
  (* Control frame during fragmentation *)
  | { header = { opcode; length = 0; _ } as h; _ }, Some _ when Opcode.is_control opcode
    -> Ok (`Frame { Frame.header = h; payload = empty_payload })
  (* Continuation frame *)
  | { header = { opcode = Continuation; final; _ }; payload }, Some h ->
    if final
    then (
      st.header <- None;
      Option.iter payload ~f:(Buffer.add_string st.buf);
      let payload = Buffer.contents st.buf in
      let payload = if must_decompress st h then decompress st.zs payload else payload in
      let length = String.length payload in
      Ok (`Frame { Frame.header = { h with final = true; rsv = 0; length }; payload }))
    else (
      Option.iter payload ~f:(Buffer.add_string st.buf);
      Ok `Continue)
  | _, Some _ -> assert false
;;

let r3_of_r2 st ({ Frame.header; payload } as frame) =
  match header.opcode with
  | _ when Opcode.is_control header.opcode && String.length payload >= 126 ->
    Error (Some (Status.ProtocolError, "control frame too big"))
  | Ping -> Ok (Some { frame with header = { header with opcode = Pong } }, None)
  | Close ->
    let status = Option.value ~default:Status.NormalClosure (Status.of_payload payload) in
    Log.debug (fun m -> m "Remote endpoint closed connection (%a)" Status.pp status);
    Error None
  | Pong ->
    (match String.length payload with
     | 0 ->
       st.on_pong None;
       Log.debug (fun m -> m "<- PONG");
       Ok (None, None)
     | _ ->
       (try
          let now = Time_ns.now () in
          let old = Time_ns.of_string payload in
          let diff = Time_ns.diff now old in
          Log.debug (fun m -> m "<- PONG %a" Time_ns.Span.pp diff);
          st.on_pong (Some diff)
        with
        | _ -> ());
       Ok (None, None))
  | Text | Binary -> Ok (None, Some frame)
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
    Error (Some (Status.UnsupportedExtension, "unsupported extension"))
;;

let heartbeat w span =
  let write_ping () =
    Log_async.debug (fun m -> m "-> PING")
    >>= fun () ->
    let ping = Frame.String.pingf "%a" Time_ns.pp (Time_ns.now ()) in
    Fastws_async_raw.write_frame_if_open w ping
  in
  let start = Time_ns.(add (now ()) span) in
  let stop = Pipe.closed w in
  Clock_ns.run_at_intervals' ~continue_on_error:false ~start ~stop span write_ping
;;

(* Slow but rarely called. *)
let maybe_add_error_code_to_frame fr =
  match Status.of_payload fr.Frame.payload with
  | Some status when Status.is_unknown status ->
    let payload = Bytes.of_string fr.payload in
    Stdlib.Bytes.set_int16_be payload 0 Status.(to_int ProtocolError);
    let payload = Bytes.unsafe_to_string ~no_mutation_while_string_reachable:payload in
    { fr with payload }
  | _ -> fr
;;

let write_close st w fr =
  match st.conn_state with
  | `Closed -> Deferred.unit
  | `Closing ->
    st.conn_state <- `Closed;
    write_frame_if_open w (maybe_add_error_code_to_frame fr)
  | `Open ->
    st.conn_state <- `Closing;
    write_frame_if_open w (maybe_add_error_code_to_frame fr)
;;

let decr_conn_state st =
  st.conn_state
    <- (match st.conn_state with
        | `Open -> `Closing
        | `Closing -> `Closed
        | `Closed -> `Closed)
;;

let check_hdr_before_reassemble { header; payload = _ } =
  Log.debug (fun m -> m "%a" Header.pp header);
  header.rsv land 3 = 0 && Opcode.is_std header.opcode
;;

exception Closing of Frame.t

let closing fr = raise (Closing fr)

let mk_r3 ?monitor of_frame st r2 w2 =
  let close_all () =
    Pipe.close_read r2;
    Pipe.close w2
  in
  let reassemble_and_process ret t =
    match check_hdr_before_reassemble t with
    | false ->
      closing @@ Frame.String.closef ~status:Status.ProtocolError "invalid header"
    | _ ->
      (match reassemble st t with
       | Error msg ->
         closing
         @@ Frame.String.close
              ~status:(Status.ProtocolError, Some ("\000\000" ^ Error.to_string_hum msg))
              ()
       | Ok `Continue -> Deferred.unit
       | Ok (`Frame fr) ->
         Log.debug (fun m -> m "<- %a" Frame.pp fr);
         (match r3_of_r2 st fr with
          | Error None ->
            (* got a close frame *)
            decr_conn_state st;
            closing fr
          | Error (Some (status, msg)) -> closing @@ Frame.String.closef ~status "%s" msg
          | Ok (for_w2, for_r3) ->
            Option.fold for_w2 ~init:Deferred.unit ~f:(fun _ -> write_frame_if_open w2)
            >>| fun () ->
            Option.iter ~f:(fun fr -> Queue.enqueue ret (of_frame fr)) for_r3))
  in
  let transferf q =
    let ret = Queue.create () in
    try_with (fun () ->
      Deferred.Queue.iter ~how:`Sequential q ~f:(reassemble_and_process ret))
    >>= function
    | Ok () -> return ret
    | Error (Closing fr) ->
      write_close st w2 fr
      >>| fun () ->
      close_all ();
      Queue.create ()
    | Error exn ->
      write_close st w2 (Frame.String.close ~status:(Status.UnsupportedDataType, None) ())
      >>| fun () ->
      close_all ();
      Option.iter monitor ~f:(fun m -> Monitor.send_exn m exn);
      Queue.create ()
  in
  Pipe.create_reader ~close_on_exception:false (fun to_r3 ->
    Pipe.transfer' r2 to_r3 ~f:transferf)
;;

let mk_w3 to_frame w2 =
  Pipe.create_writer (fun from_w3 ->
    Pipe.transfer from_w3 w2 ~f:(fun pl ->
      let { Frame.header; payload } = to_frame pl in
      { header; payload = (if String.length payload = 0 then None else Some payload) }))
;;

type ('r, 'w) t =
  { r : 'r Pipe.Reader.t
  ; w : 'w Pipe.Writer.t
  }
[@@deriving fields]

let string_of_frame { Frame.payload; _ } = payload
let frame_of_string payload = Frame.String.text payload
let cut_of_frame { Frame.payload; _ } = payload ^ "\x00"

let frame_of_cut payload =
  Frame.String.text
    (String.strip
       ~drop:(function
         | '\x00' -> true
         | _ -> false)
       payload)
;;

let connect_frame ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb url r w =
  (* Never raise an exception here. *)
  Monitor.try_with_join_or_error (fun () ->
    Fastws_async_raw.to_or_error
      (connect ?extra_headers ?extensions ?protocols ?monitor url r w
       >>=? fun (exts, r2, w2) ->
       let permessage_deflate =
         List.Assoc.mem ~equal:String.equal exts "permessage-deflate"
       in
       let st = create_st ~permessage_deflate ?on_pong () in
       Option.iter hb ~f:(heartbeat w2);
       let r3 = mk_r3 ?monitor string_of_frame st r2 w2 in
       let w3 = mk_w3 frame_of_string w2 in
       (Pipe.closed r3 >>> fun () -> Pipe.close_read r2);
       (Deferred.all_unit [ Pipe.closed w3; Pipe.closed r3 ]
        >>> fun () ->
        close_st st;
        Pipe.close w2);
       Deferred.Result.return (r3, w3)))
;;

let connect_text ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb url r w =
  Fastws_async_raw.to_or_error
    (connect ?extra_headers ?extensions ?protocols ?monitor url r w
     >>=? fun (exts, r2, w2) ->
     let permessage_deflate =
       List.Assoc.mem ~equal:String.equal exts "permessage-deflate"
     in
     let st = create_st ~permessage_deflate ?on_pong () in
     Option.iter hb ~f:(heartbeat w2);
     let r3 = mk_r3 ?monitor cut_of_frame st r2 w2 in
     let w3 = mk_w3 frame_of_cut w2 in
     (Pipe.closed r3 >>> fun () -> Pipe.close_read r2);
     (Deferred.all_unit [ Pipe.closed w3; Pipe.closed r3 ]
      >>> fun () ->
      close_st st;
      Pipe.close w2);
     Reader.of_pipe (Info.of_string "") r3
     >>= fun reader ->
     Writer.of_pipe (Info.of_string "") w3
     >>= fun (writer, `Closed_and_flushed_downstream _closed) ->
     Deferred.Result.return (reader, writer))
;;

let connect
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  url
  r
  w
  of_frame
  to_frame
  =
  connect ?extra_headers ?extensions ?protocols ?monitor url r w
  >>|? fun (exts, r2, w2) ->
  let permessage_deflate = List.Assoc.mem ~equal:String.equal exts "permessage-deflate" in
  let st = create_st ~permessage_deflate ?on_pong () in
  Option.iter hb ~f:(heartbeat w2);
  let r3 = mk_r3 ?monitor of_frame st r2 w2 in
  let w3 = mk_w3 to_frame w2 in
  (Pipe.closed r3 >>> fun () -> Pipe.close_read r2);
  (Deferred.all_unit [ Pipe.closed w3; Pipe.closed r3 ]
   >>> fun () ->
   close_st st;
   Pipe.close w2);
  Fields.create ~r:r3 ~w:w3
;;

let with_connection
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  url
  r
  w
  of_frame
  to_frame
  f
  =
  connect
    ?on_pong
    ?extra_headers
    ?extensions
    ?protocols
    ?monitor
    ?hb
    url
    r
    w
    of_frame
    to_frame
  >>=? fun { r = r3; w = w3 } ->
  Monitor.protect
    (fun () -> f r3 w3 >>| fun res -> Ok res)
    ~finally:(fun () ->
      (* Do closing stuff but do not report exn on this to avoid
         hiding cause of previous error or eat results. *)
      Monitor.try_with (fun () ->
        Pipe.close_read r3;
        Pipe.close w3;
        Deferred.unit)
      >>= fun _ign -> Deferred.unit)
;;

let with_connection'
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  url
  r
  w
  of_frame
  to_frame
  f
  =
  Fastws_async_raw.to_or_error
    (with_connection
       ?on_pong
       ?extra_headers
       ?extensions
       ?protocols
       ?monitor
       ?hb
       url
       r
       w
       of_frame
       to_frame
       f)
;;

let with_connection_frame
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  url
  r
  w
  f
  =
  Fastws_async_raw.to_or_error
    (with_connection
       ?on_pong
       ?extra_headers
       ?extensions
       ?protocols
       ?monitor
       ?hb
       url
       r
       w
       string_of_frame
       frame_of_string
       (fun r w ->
         Monitor.protect
           (fun () -> f r w)
           ~finally:(fun () ->
             Pipe.close w;
             Pipe.close_read r;
             Deferred.unit)))
;;

let with_connection_text
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  url
  r
  w
  f
  =
  Fastws_async_raw.to_or_error
    (with_connection
       ?on_pong
       ?extra_headers
       ?extensions
       ?protocols
       ?monitor
       ?hb
       url
       r
       w
       cut_of_frame
       frame_of_cut
       (fun r w ->
         Reader.of_pipe (Info.of_string "") r
         >>= fun reader ->
         Writer.of_pipe (Info.of_string "") w
         >>= fun (writer, `Closed_and_flushed_downstream _closed) ->
         Monitor.protect
           (fun () -> f reader writer)
           ~finally:(fun () ->
             Deferred.all_unit [ Writer.close writer; Reader.close reader ])))
;;

let of_frame_s { Frame.payload; _ } = payload
let to_frame_s msg = Frame.String.textf "%s" msg

let connect_or_result
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  of_frame
  to_frame
  url
  =
  Async_uri.connect url
  >>= fun { r; w; _ } ->
  Monitor.try_with ~extract_exn:true (fun () ->
    connect
      ?on_pong
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      url
      r
      w
      of_frame
      to_frame)
  >>= function
  | Error exn -> Writer.close w >>= fun () -> raise exn
  | Ok x -> return x
;;

let connect_or_error
  ?timeout
  ?on_pong
  ?extra_headers
  ?extensions
  ?protocols
  ?monitor
  ?hb
  of_frame
  to_frame
  url
  =
  let f () =
    Async_uri.connect url
    >>= fun { r; w; _ } ->
    Monitor.try_with ~extract_exn:true (fun () ->
      connect
        ?on_pong
        ?extra_headers
        ?extensions
        ?protocols
        ?monitor
        ?hb
        url
        r
        w
        of_frame
        to_frame)
    >>= function
    | Error exn -> Writer.close w >>= fun () -> raise exn
    | Ok x -> to_or_error (return x)
  in
  match timeout with
  | None -> f ()
  | Some timeout ->
    Clock_ns.with_timeout timeout (f ())
    >>| (function
    | `Timeout -> Or_error.error_string "timeout"
    | `Result x -> x)
;;

module Raw = Fastws_async_raw

(*---------------------------------------------------------------------------
  Copyright (c) 2020 DeepMarker

  Permission to use, copy, modify, and/or distribute this software for any
  purpose with or without fee is hereby granted, provided that the above
  copyright notice and this permission notice appear in all copies.

  THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
  ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
  OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
