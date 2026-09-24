(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
module Time_ns = Time_ns_unix
open Fastws
open Fastws_async_raw

module State = struct
  type state =
    | Open
    | Close_sent
    | Close_recv
    | Closed

  type t =
    { buf : Buffer.t
    ; mutable header : Header.t option
    ; mutable conn_state : state
    ; on_pong : Time_ns.t option -> unit
    ; on_close : Close_frame.t -> unit
    ; mutable dec : Permessage_deflate.t option
    ; mutable last_recv : Time_ns.t
      (** When a frame was last read from the peer, of any kind -- a pong, a
            close, a data frame. What {!liveness} watches. *)
    }

  let create ?dec ?(on_pong = Fn.ignore) ?(on_close = Fn.ignore) () =
    { buf = Buffer.create 4096
    ; header = None
    ; on_pong
    ; on_close
    ; conn_state = Open
    ; dec
    ; last_recv = Time_ns.now ()
    }
  ;;

  let must_decompress st (h : Header.t) = Option.is_some st.dec && h.rsv = 4

  let close t =
    Option.iter t.dec ~f:Permessage_deflate.close;
    t.dec <- None
  ;;
end

let%trace reassemble (st : State.t) (t : Frame.t) =
  match t, st.header with
  (* Erroneous cases *)
  | { header = { opcode; final = false; _ }; _ }, _ when Opcode.is_control opcode ->
    Format.kasprintf Or_error.error_string "fragmented control frame"
  | { header = { opcode; final = true; _ }; _ }, Some _
    when not Opcode.(is_control opcode || is_continuation opcode) ->
    Format.kasprintf Or_error.error_string "unfinished continuation"
  | { header = { opcode = Continuation; _ }; _ }, None ->
    Format.kasprintf Or_error.error_string "orphan continuation frame"
  (* Continuation frames must not have RSV1 set *)
  | { header = { opcode = Continuation; rsv; _ }; _ }, Some _ when rsv <> 0 ->
    Format.kasprintf Or_error.error_string "continuation frame with RSV bits set"
  (* Non-segmented frame *)
  | { header = { final = true; _ } as h; payload }, None ->
    (match payload with
     | "" -> Ok (Some { Frame.header = h; payload = "" })
     | payload when not (State.must_decompress st h) ->
       let header = { h with length = String.length payload } in
       Ok (Some { Frame.header; payload })
     | payload ->
       (* Decompress the payload *)
       Option.value_map
         st.dec
         ~default:(Or_error.error_string "Compression context not available")
         ~f:(fun dec ->
           Or_error.try_with (fun () -> Permessage_deflate.decompress_exn dec payload)
           |> Or_error.map ~f:(fun decompressed ->
             let header = { h with length = String.length decompressed; rsv = 0 } in
             Some { Frame.header; payload = decompressed })))
  (* Non final first frame *)
  | { header = { final = false; _ } as h; payload }, None ->
    st.header <- Some h;
    Buffer.clear st.buf;
    Buffer.add_string st.buf payload;
    Ok None
  (* Control frame during fragmentation. RFC 6455 §5.4 lets a control frame
     be injected between the fragments of a message, and §5.5 lets it carry
     up to 125 bytes of payload -- a close reason, a ping body. Requiring an
     empty payload here sent every other control frame to the catch-all
     below, which asserted: a venue closing a connection with a reason while
     a fragmented message was in flight took the worker down rather than
     reporting the close. [r3_of_r2] is what rejects an oversized control
     frame, so the length is not this function's business.

     The fragmentation state is deliberately untouched: the control frame
     passes through and the message it interrupted keeps reassembling. *)
  | { header = { opcode; _ } as h; payload }, Some _ when Opcode.is_control opcode ->
    Ok (Some { Frame.header = h; payload })
  (* Continuation frame *)
  | { header = { opcode = Continuation; final; _ }; payload }, Some h ->
    Buffer.add_string st.buf payload;
    if not final
    then Ok None
    else (
      st.header <- None;
      let payload = Buffer.contents st.buf in
      (* decompress or not based on the FIRST frame's header *)
      if not (State.must_decompress st h)
      then (
        let length = String.length payload in
        let header = { h with final = true; rsv = 0; length } in
        Ok (Some { Frame.header; payload }))
      else
        (* Decompress the complete fragmented message *)
        Option.value_map
          st.dec
          ~default:(Or_error.error_string "Compression context not available")
          ~f:(fun dec ->
            Or_error.try_with (fun () -> Permessage_deflate.decompress_exn dec payload)
            |> Or_error.map ~f:(fun decompressed ->
              let length = String.length decompressed in
              let header = { h with final = true; rsv = 0; length } in
              Some { Frame.header; payload = decompressed })))
  (* A new non-final data frame while another message is still being
     reassembled: the peer started a second message without finishing the
     first, which RFC 6455 §5.4 forbids. Reported rather than asserted --
     it is a statement about the peer, not about this code. *)
  | { header = { opcode; _ }; _ }, Some _ ->
    Format.kasprintf
      Or_error.error_string
      "interleaved message: %a began before the previous one finished"
      Opcode.pp
      opcode
;;

let r3_of_r2 src (st : State.t) ({ Frame.header; payload } as frame) =
  match header.opcode with
  | _ when Opcode.is_control header.opcode && String.length payload >= 126 ->
    Result.fail (Some (Status.ProtocolError, "control frame too big"))
  | Ping ->
    Ok (Some { frame with header = { header with opcode = Pong; mask = None } }, None)
  | Close ->
    (match Close_frame.of_payload payload with
     | Error Close_frame.Invalid_utf8_reason ->
       Error (Some (Status.InconsistentData, "close reason is not valid UTF-8"))
     | Error error ->
       Error
         (Some
            ( Status.ProtocolError
            , Format.asprintf "invalid close frame: %a" Close_frame.pp_error error ))
     | Ok close ->
       st.on_close close;
       let status = Option.map close.code ~f:Status.of_int in
       (match status with
        | None | Some (NormalClosure | GoingAway) ->
          Logs.debug ~src (fun m ->
            m "Remote endpoint closed connection %a" Close_frame.pp close)
        | Some _ ->
          Logs.err ~src (fun m ->
            m "Remote endpoint closed connection with error %a" Close_frame.pp close));
       Error None)
  | Pong ->
    (match String.length payload with
     | 0 ->
       st.on_pong None;
       Logs.debug ~src (fun m -> m "<- PONG");
       Ok (None, None)
     | _ ->
       if String.length payload = 8
       then (
         let old =
           let buf = Bytes.unsafe_of_string_promise_no_mutation payload in
           let ts = Bytes.unsafe_get_int64 buf 0 in
           Time_ns.of_int63_ns_since_epoch (Int63.of_int64_exn ts)
         in
         Logs.debug ~src (fun m -> m "<- PONG old: %a" Time_ns.pp old);
         st.on_pong (Some old))
       else (
         st.on_pong None;
         Logs.debug ~src (fun m -> m "<- PONG %s" payload));
       ();
       Ok (None, None))
  | Text | Binary -> Ok (None, Some frame)
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
    Error (Some (Status.UnsupportedExtension, "unsupported extension"))
;;

let heartbeat src w span =
  let buf = Bytes.create 8 in
  let now_str () =
    Time_ns.(now () |> to_int63_ns_since_epoch)
    |> Int63.to_int64
    |> fun x ->
    Bytes.unsafe_set_int64 buf 0 x;
    Bytes.to_string buf
  in
  let write_ping () =
    Logs_async.debug ~src (fun m -> m "-> PING")
    >>= fun () ->
    let ping = Frame.String.ping (now_str ()) in
    Pipe.write_if_open w ping
  in
  let start = Time_ns.(add (now ()) span) in
  let stop = Pipe.closed w in
  Clock_ns.run_at_intervals' ~continue_on_error:false ~start ~stop span write_ping
;;

(* Declare a connection dead when the peer's *application* has sent nothing for
   [span].

   A write proves nothing about the peer: it succeeds into the kernel's send
   buffer whether or not anyone is still listening, and the failure only
   surfaces when TCP gives up retransmitting -- [tcp_retries2], a quarter of an
   hour on a default Linux. That is what a machine resuming from suspend
   produces: sockets still ESTABLISHED, data piling up unacknowledged, and a
   feed that reads as subscribed while delivering nothing.

   So the clock runs on what arrives -- but only on what arrives *for the
   application*, which is Text and Binary. A native pong does not count, and
   that is the whole point of the distinction: RFC 6455 ping/pong is answered
   by the peer's websocket library, below and independently of whatever is
   producing market data, so a pong says the library is alive and says nothing
   about the feed behind it. A venue whose publisher has wedged while its
   library keeps pouring out pongs is exactly the connection this exists to
   catch, and counting pongs would make it invisible.

   What that costs is that native pings can no longer keep a quiet connection
   off the deadline. The evidence has to be application traffic: the venue's
   data, or its answer to the venue's own application-level ping, which is an
   ordinary Text frame and counts like any other. Every venue that defines such
   a ping wants it used, and this is why. *)
let liveness src (st : State.t) span r2 w2 =
  (* Check several times per deadline: on a period equal to [span] a
     connection can go up to twice the deadline before anyone looks. The floor
     only keeps the timer off a hot loop -- real deadlines are seconds, so it
     does not bind in production. *)
  let period = Time_ns.Span.(max (span / 4.) (of_int_ms 100)) in
  Clock_ns.every ~stop:(Pipe.closed w2) period (fun () ->
    let elapsed = Time_ns.diff (Time_ns.now ()) st.last_recv in
    if Time_ns.Span.( > ) elapsed span && not (Pipe.is_closed r2)
    then (
      Logs.err ~src (fun m ->
        m
          "no frame received for %a, declaring the connection dead"
          Time_ns.Span.pp
          elapsed);
      Pipe.close_read r2;
      Pipe.close w2))
;;

let write_close (st : State.t) w fr =
  match st.conn_state with
  | Closed | Close_sent -> ()
  | Close_recv ->
    st.conn_state <- Closed;
    Pipe.write_without_pushback_if_open w fr
  | Open ->
    st.conn_state <- Close_sent;
    Pipe.write_without_pushback_if_open w fr
;;

let decr_conn_state (st : State.t) =
  st.conn_state
  <- (match st.conn_state with
      | Open | Close_recv -> Close_recv
      | Close_sent -> Closed
      | Closed -> Closed)
;;

(* RFC 6455 §5.2: a reserved bit set with no negotiated meaning MUST fail the
   connection. RSV2 and RSV3 never have one here -- fastws negotiates no
   extension that defines them -- so they are always a violation.

   RSV1 is the compressed-message bit, and it has a meaning only once
   permessage-deflate has actually been negotiated. Accepting it
   unconditionally, as this used to, meant a peer could set it on a connection
   with no extension at all and have the frame delivered to the application
   still deflate-compressed, its header carrying an rsv the caller has no way
   to interpret. Autobahn case 3.4 is exactly that, and it was the only failure
   in the suite outside the UTF-8 section.

   RFC 7692 §6.1 confines RSV1 further, to the first frame of a data message:
   never on a control frame, which is never compressed, and never on a
   continuation, which [reassemble] rejects separately. *)
let check_hdr_before_reassemble (st : State.t) { Frame.header; payload = _ } =
  Opcode.is_std header.opcode
  &&
  match header.rsv with
  | 0 -> true
  | 4 ->
    Option.is_some st.dec
    &&
      (match header.opcode with
      | Text | Binary -> true
      | _ -> false)
  | _ -> false
;;

exception Closing of Frame.t

let%trace reassemble_and_process src st of_frame w2 ret t =
  match check_hdr_before_reassemble st t with
  | false ->
    raise (Closing (Frame.String.closef ~status:Status.ProtocolError "invalid header"))
  | _ ->
    (match reassemble st t with
     | Error msg ->
       Logs.err ~src (fun m -> m "reassemble error: %a" Error.pp msg);
       raise
         (Closing
            (Frame.String.close
               ~status:(Status.ProtocolError, Some ("\000\000" ^ Error.to_string_hum msg))
               ()))
     | Ok None -> ()
     | Ok (Some fr) ->
       Logs.debug ~src (fun m -> m "<- %a" Frame.pp fr);
       (match r3_of_r2 src st fr with
        | Error None ->
          (* got a close frame *)
          decr_conn_state st;
          raise (Closing fr)
        | Error (Some (status, msg)) ->
          raise (Closing (Frame.String.closef ~status "%s" msg))
        | Ok (for_w2, for_r3) ->
          Option.iter for_w2 ~f:(Pipe.write_without_pushback_if_open w2);
          Option.iter for_r3 ~f:(fun fr ->
            (* Only a frame that reaches the application counts as liveness --
               see {!liveness}. Text and Binary are the two that get here; a
               native pong stops at [r3_of_r2] above and never does. *)
            st.State.last_recv <- Time_ns.now ();
            Queue.enqueue ret (of_frame fr))))
;;

let mk_r3 ?monitor of_frame src st r2 w2 =
  let close_all () =
    Pipe.close_read r2;
    Pipe.close w2
  in
  let transferf q =
    let ret = Queue.create () in
    (try Queue.iter q ~f:(reassemble_and_process src st of_frame w2 ret) with
     | Closing fr ->
       write_close st w2 fr;
       close_all ()
     | exn ->
       let status = Status.UnsupportedDataType in
       let close_frame = Frame.String.close ~status:(status, None) () in
       write_close st w2 close_frame;
       close_all ();
       Option.iter monitor ~f:(fun m -> Monitor.send_exn m exn));
    return ret
  in
  Pipe.create_reader ~close_on_exception:false (fun to_r3 ->
    Pipe.transfer' r2 to_r3 ~f:transferf)
;;

let mk_w3 (st : State.t) to_frame w2 =
  let to_frame =
    match st.dec with
    | None -> to_frame
    | Some dec ->
      let to_frame_compressed x =
        let frame = to_frame x in
        (* Compress frame *)
        match frame.Frame.header.opcode with
        | Text | Binary ->
          (* Compress text/binary frames. *)
          let compressed = Permessage_deflate.compress_exn dec frame.Frame.payload in
          Frame.with_compressed_payload frame compressed
        | _ -> frame
      in
      to_frame_compressed
  in
  Pipe.create_writer (fun from_w3 ->
    Pipe.transfer from_w3 w2 ~f:to_frame
    >>= fun () ->
    (* at this point from_w3 is closed, send close frame *)
    write_close st w2 (Frame.String.close ());
    Deferred.unit)
;;

type ('r, 'w) t =
  { r : 'r Pipe.Reader.t
  ; w : 'w Pipe.Writer.t
  }
[@@deriving fields]

let default_log = Logs.Src.create "fastws.async"

let dec_of_exts exts =
  let params = List.Assoc.find ~equal:String.Caseless.equal exts "permessage-deflate" in
  Option.map ~f:(Permessage_deflate.of_params `Client) params
;;

let after_init ?hb ?max_idle ?dec ?on_pong ?on_close ?monitor src r2 w2 of_frame to_frame =
  let st = State.create ?dec ?on_pong ?on_close () in
  Option.iter hb ~f:(heartbeat src w2);
  Option.iter max_idle ~f:(fun span -> liveness src st span r2 w2);
  let r3 = mk_r3 ?monitor of_frame src st r2 w2 in
  let w3 = mk_w3 st to_frame w2 in
  (Pipe.closed w3 >>> fun () -> Pipe.close_read r3);
  (Pipe.closed r3 >>> fun () -> Pipe.close_read r2);
  (Deferred.all_unit [ Pipe.closed w3; Pipe.closed r3 ]
   >>> fun () ->
   State.close st;
   Pipe.close w2);
  Fields.create ~r:r3 ~w:w3
;;

let connect
      ?(src = default_log)
      ?on_pong
      ?on_close
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      ?max_idle
      url
      r
      w
      of_frame
      to_frame
  =
  connect ?extra_headers ?extensions ?protocols ?monitor src url r w
  >>|? fun (exts, r2, w2) ->
  let dec = dec_of_exts exts in
  after_init ?hb ?max_idle ?dec ?on_pong ?on_close ?monitor src r2 w2 of_frame to_frame
;;

let of_initialized
      ?(src = default_log)
      ?on_pong
      ?on_close
      ?monitor
      ?hb
      ?max_idle
      r
      w
      headers
      of_frame
      to_frame
  =
  let exts = get_extensions headers in
  let dec = dec_of_exts exts in
  let r2, w2 = of_initialized ?monitor src r w in
  after_init ?hb ?max_idle ?dec ?on_pong ?on_close ?monitor src r2 w2 of_frame to_frame
;;

(* The server side of the opening handshake (RFC 6455, section 4.2): read the
   client's upgrade request off the socket, check it, and answer 101 with the
   proof that this server read the key. The connection that follows is the
   same one [connect] gives a client, built by [of_initialized], whose frames
   go out unmasked, as a server's must.

   permessage-deflate is not offered: the RFC lets a server decline every
   extension, and a client then sends and expects plain frames. *)
module Server = struct
  type request =
    { target : string
    ; headers : Httpun.Headers.t
    }

  (* The whole request head, request line and header lines, is bounded: an
     upgrade request is a few hundred bytes, and a peer that sends more is not
     a WebSocket client. *)
  let max_head_bytes = 16 * 1024
  let max_head_lines = 100

  let read_head r =
    let rec loop acc ~bytes ~lines =
      Reader.read_line r
      >>= function
      | `Eof -> return (Error "connection closed before the request was complete")
      | `Ok "" -> return (Ok (List.rev acc))
      | `Ok line ->
        let bytes = bytes + String.length line in
        if bytes > max_head_bytes || lines >= max_head_lines
        then return (Error "request head too large")
        else loop (line :: acc) ~bytes ~lines:(lines + 1)
    in
    loop [] ~bytes:0 ~lines:0
  ;;

  let parse_header line =
    match String.lsplit2 line ~on:':' with
    | Some (name, value) when not (String.is_empty (String.strip name)) ->
      Ok (String.strip name, String.strip value)
    | Some _ | None -> Error (sprintf "malformed header line %S" line)
  ;;

  (* Comma-separated tokens, compared without case: "Connection: keep-alive,
     Upgrade" is an upgrade request. *)
  let tokens headers name =
    Httpun.Headers.get_multi headers name
    |> List.concat_map ~f:(String.split ~on:',')
    |> List.map ~f:(fun s -> String.lowercase (String.strip s))
  ;;

  let has_token headers name token =
    List.mem (tokens headers name) token ~equal:String.equal
  ;;

  let accept_proof key =
    Digestif.SHA1.(digest_string (key ^ websocket_uuid) |> to_raw_string)
    |> Base64.encode_exn ~pad:true
  ;;

  let write_response w ~status ~headers =
    Writer.write w (sprintf "HTTP/1.1 %s\r\n" status);
    List.iter headers ~f:(fun (name, value) -> Writer.writef w "%s: %s\r\n" name value);
    Writer.write w "\r\n"
  ;;

  (* A refused request is answered, not dropped: a client learns why. *)
  let refuse w ~status ?(headers = []) why =
    write_response
      w
      ~status
      ~headers:(headers @ [ "Content-Length", "0"; "Connection", "close" ]);
    Writer.flushed w >>| fun () -> Or_error.error_string why
  ;;

  let check_request lines =
    let open Result.Let_syntax in
    let%bind request_line, header_lines =
      match lines with
      | [] -> Error (`Bad "empty request")
      | l :: rest -> Ok (l, rest)
    in
    let%bind target =
      match String.split request_line ~on:' ' with
      | [ "GET"; target; "HTTP/1.1" ] -> Ok target
      | _ -> Error (`Bad (sprintf "not a GET HTTP/1.1 request: %S" request_line))
    in
    let%bind headers =
      List.map header_lines ~f:parse_header
      |> Result.all
      |> Result.map_error ~f:(fun e -> `Bad e)
    in
    let headers = Httpun.Headers.of_list headers in
    let%bind () =
      if has_token headers "upgrade" "websocket"
      then Ok ()
      else Error (`Bad "missing Upgrade: websocket")
    in
    let%bind () =
      if has_token headers "connection" "upgrade"
      then Ok ()
      else Error (`Bad "missing Connection: Upgrade")
    in
    let%bind () =
      match Httpun.Headers.get headers "sec-websocket-version" with
      | Some v when String.equal (String.strip v) "13" -> Ok ()
      | Some _ | None -> Error `Version
    in
    let%map key =
      match Httpun.Headers.get headers "sec-websocket-key" with
      | Some key ->
        let key = String.strip key in
        (match Base64.decode key with
         | Ok raw when String.length raw = 16 -> Ok key
         | Ok _ | Error _ -> Error (`Bad "Sec-WebSocket-Key is not 16 base64 bytes"))
      | None -> Error (`Bad "missing Sec-WebSocket-Key")
    in
    { target; headers }, key
  ;;

  let accept
        ?(src = default_log)
        ?on_pong
        ?on_close
        ?monitor
        ?hb
        ?max_idle
        ?(protocol = fun (_ : string list) -> None)
        ?(extra_headers = [])
        r
        w
        of_frame
        to_frame
    =
    read_head r
    >>= function
    | Error why -> refuse w ~status:"400 Bad Request" why
    | Ok lines ->
      (match check_request lines with
       | Error (`Bad why) -> refuse w ~status:"400 Bad Request" why
       | Error `Version ->
         refuse
           w
           ~status:"426 Upgrade Required"
           ~headers:[ "Sec-WebSocket-Version", "13" ]
           "unsupported Sec-WebSocket-Version"
       | Ok (request, key) ->
         let chosen = protocol (tokens request.headers "sec-websocket-protocol") in
         write_response
           w
           ~status:"101 Switching Protocols"
           ~headers:
             ([ "Upgrade", "websocket"
              ; "Connection", "Upgrade"
              ; "Sec-WebSocket-Accept", accept_proof key
              ]
              @ Option.value_map chosen ~default:[] ~f:(fun p ->
                [ "Sec-WebSocket-Protocol", p ])
              @ extra_headers);
         let conn =
           of_initialized
             ~src
             ?on_pong
             ?on_close
             ?monitor
             ?hb
             ?max_idle
             r
             w
             Httpun.Headers.empty
             of_frame
             to_frame
         in
         Deferred.Or_error.return (request, conn))
  ;;

  (* One handler per connection. When it returns, the connection is closed, as
     the TCP server closes the socket it came on. A request that is not a
     WebSocket upgrade is answered and closed without reaching the handler. *)
  let serve
        ?src
        ?on_pong
        ?on_close
        ?monitor
        ?hb
        ?max_idle
        ?protocol
        ?extra_headers
        ?(on_refused = fun (_ : Socket.Address.Inet.t) (_ : Error.t) -> ())
        where
        of_frame
        to_frame
        handler
    =
    Tcp.Server.create ~on_handler_error:`Ignore where (fun addr r w ->
      accept
        ?src
        ?on_pong
        ?on_close
        ?monitor
        ?hb
        ?max_idle
        ?protocol
        ?extra_headers
        r
        w
        of_frame
        to_frame
      >>= function
      | Error e ->
        on_refused addr e;
        Deferred.unit
      | Ok (request, conn) ->
        Monitor.protect
          (fun () -> handler addr request conn)
          ~finally:(fun () ->
            Pipe.close conn.w;
            Pipe.close_read conn.r;
            Deferred.unit))
  ;;
end

let with_connection
      ?src
      ?on_pong
      ?on_close
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      ?max_idle
      url
      r
      w
      of_frame
      to_frame
      f
  =
  connect
    ?on_pong
    ?on_close
    ?extra_headers
    ?extensions
    ?protocols
    ?monitor
    ?hb
    ?max_idle
    ?src
    url
    r
    w
    of_frame
    to_frame
  >>=? fun { r = r3; w = w3 } ->
  let finally () =
    (* Do closing stuff but do not report exn on this to avoid
         hiding cause of previous error or eat results. *)
    Monitor.try_with (fun () ->
      Pipe.close_read r3;
      Pipe.close w3;
      Deferred.unit)
    >>= fun _ign -> Deferred.unit
  in
  Monitor.protect (fun () -> f r3 w3 >>| fun res -> Ok res) ~finally
;;

let with_connection'
      ?src
      ?on_pong
      ?on_close
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      ?max_idle
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
       ?on_close
       ?extra_headers
       ?extensions
       ?protocols
       ?monitor
       ?hb
       ?max_idle
       ?src
       url
       r
       w
       of_frame
       to_frame
       f)
;;

let of_frame_s { Frame.payload; _ } = payload
let to_frame_s msg = Frame.String.textf "%s" msg

let connect_or_result
      ?src
      ?on_pong
      ?on_close
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      ?max_idle
      of_frame
      to_frame
      url
  =
  Async_uri.connect url
  >>= fun { r; w; _ } ->
  Monitor.try_with ~extract_exn:true (fun () ->
    connect
      ?on_pong
      ?on_close
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      ?max_idle
      ?src
      url
      r
      w
      of_frame
      to_frame)
  >>= function
  | Error exn ->
    Deferred.all_unit [ Writer.close w; Reader.close r ] >>= fun () -> raise exn
  | Ok x -> return x
;;

let connect_or_error
      ?src
      ?timeout
      ?on_pong
      ?on_close
      ?extra_headers
      ?extensions
      ?protocols
      ?monitor
      ?hb
      ?max_idle
      of_frame
      to_frame
      url
  =
  let f () =
    Monitor.try_with ~extract_exn:true (fun () ->
      Async_uri.connect ?timeout url
      >>= fun { r; w; _ } ->
      Monitor.try_with ~extract_exn:true (fun () ->
        connect
          ?on_pong
          ?on_close
          ?extra_headers
          ?extensions
          ?protocols
          ?monitor
          ?hb
          ?max_idle
          ?src
          url
          r
          w
          of_frame
          to_frame)
      >>= function
      | Error exn ->
        (* On writing error, close both, because the connection is likely dead. *)
        Deferred.all_unit [ Writer.close w; Reader.close r ] >>= fun () -> raise exn
      | Ok x -> to_or_error (return x))
    >>= function
    | Error exn -> return (Or_error.of_exn exn)
    | Ok result -> return result
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

module For_testing = struct
  (* Drive the fragment reassembler over a sequence of frames on one
     connection state, which is otherwise unreachable from a test: it lives
     behind [of_initialized] and a real socket. *)
  let reassemble frames =
    let st = State.create () in
    List.map frames ~f:(fun frame -> reassemble st frame)
  ;;

  (* Whether a header is acceptable on a connection that did or did not
     negotiate permessage-deflate. The check is otherwise reachable only
     behind [of_initialized] and a real socket, and what it accepts depends on
     negotiation state that a caller cannot reach at all. *)
  let check_hdr ~deflate frame =
    let dec = if deflate then Some (Permessage_deflate.of_params `Client []) else None in
    let st = State.create ?dec () in
    let ok = check_hdr_before_reassemble st frame in
    State.close st;
    ok
  ;;
end
