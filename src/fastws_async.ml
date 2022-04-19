(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Fastws
open Fastws_async_raw

let src = Logs.Src.create "fastws.async"

module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

let empty_payload = Bigstring.create 0

type st =
  { buf: Bigbuffer.t;
    mutable header: Header.t option;
    mutable conn_state: [`Open | `Closing | `Closed];
    on_pong: Time_ns_unix.Span.t option -> unit;
    permessage_deflate: bool;
    inflate: Zlib.inflate Zlib.t }

let create_st ?(permessage_deflate = false) ?(on_pong = Fn.ignore) () =
  { buf= Bigbuffer.create 4096;
    header= None;
    conn_state= `Open;
    on_pong;
    permessage_deflate;
    inflate= Zlib.create_inflate ~window_bits:~-15 () }

let must_decompress (st : st) (h : Header.t) =
  st.permessage_deflate && h.rsv = 4

let decomp_trailer =
  Bigstring.init 4 ~f:(function 0 | 1 -> '\x00' | _ -> '\xff')

let buf = Bigbuffer.create 256

let decompress st msg =
  Bigbuffer.clear buf ;
  let outbuf = Bigbuffer.volatile_contents st.buf in
  let rec loop added_trailer =
    let flush = if added_trailer then Zlib.Sync_flush else No_flush in
    match Zlib.flate st.inflate flush with
    | Ok ->
        let x = Bigstring.sub_shared outbuf ~len:st.inflate.out_ofs in
        Bigbuffer.add_bigstring buf x ;
        st.inflate.out_ofs <- 0 ;
        st.inflate.out_len <- Bigstring.length outbuf ;
        if st.inflate.in_len > 0 then loop added_trailer
        else if not added_trailer then (
          st.inflate.in_buf <- decomp_trailer ;
          st.inflate.in_ofs <- 0 ;
          st.inflate.in_len <- 4 ;
          loop true )
        else
          let x = Bigstring.sub_shared outbuf ~len:st.inflate.out_ofs in
          Bigbuffer.add_bigstring buf x
    | Stream_end -> failwith "zlib: stream end"
    | Need_dict -> failwith "zlib: need dict"
    | Buf_error -> failwith "zlib: buf error"
    | Data_error msg -> failwithf "zlib: %s" msg () in
  (* entry point *)
  st.inflate.in_buf <- msg ;
  st.inflate.in_ofs <- 0 ;
  st.inflate.in_len <- Bigstring.length msg ;
  st.inflate.out_buf <- outbuf ;
  st.inflate.out_ofs <- 0 ;
  st.inflate.out_len <- Bigstring.length outbuf ;
  loop false ;
  Bigbuffer.big_contents buf

let reassemble st (t : Fastws_async_raw.t) =
  match (t, st.header) with
  (* Erroneous cases *)
  | {header= {opcode; final= false; _}; _}, _ when Opcode.is_control opcode ->
      Format.kasprintf Or_error.error_string "fragmented control frame"
  | {header= {opcode; final= true; _}; _}, Some _
    when not Opcode.(is_control opcode || is_continuation opcode) ->
      Format.kasprintf Or_error.error_string "unfinished continuation"
  | {header= {opcode= Continuation; _}; _}, None ->
      Format.kasprintf Or_error.error_string "orphan continuation frame"
  (* Final frame  *)
  | {header= {final= true; _} as h; payload}, None -> (
    match (payload, must_decompress st h) with
    | None, _ -> Ok (`Frame {Frame.header= h; payload= empty_payload})
    | Some payload, false -> Ok (`Frame {Frame.header= h; payload})
    | Some payload, true ->
        let payload = decompress st payload in
        let header = {h with length= Bigstring.length payload} in
        Ok (`Frame {Frame.header; payload}) )
  (* Non final first frame *)
  | {header= {final= false; _} as h; payload}, None ->
      st.header <- Some h ;
      Bigbuffer.clear st.buf ;
      Option.iter payload ~f:(Bigbuffer.add_bigstring st.buf) ;
      Ok `Continue
  (* Control frame during fragmentation *)
  | {header= {opcode; length= 0; _} as h; _}, Some _
    when Opcode.is_control opcode ->
      Ok (`Frame {Frame.header= h; payload= empty_payload})
  (* Continuation frame *)
  | {header= {opcode= Continuation; final; _} as ch; payload}, Some h ->
      if final then (
        st.header <- None ;
        Option.iter payload ~f:(Bigbuffer.add_bigstring st.buf) ;
        let payload = Bigbuffer.big_contents st.buf in
        let payload =
          if must_decompress st h then decompress st payload else payload in
        let length = Bigstring.length payload in
        Ok (`Frame {Frame.header= {h with length}; payload}) )
      else (
        st.header <- Some {ch with opcode= h.opcode} ;
        Option.iter payload ~f:(Bigbuffer.add_bigstring st.buf) ;
        Ok `Continue )
  | _, Some _ -> assert false

let r3_of_r2 st ({Frame.header; payload} as frame) =
  match header.opcode with
  | _ when Opcode.is_control header.opcode && Bigstring.length payload >= 126 ->
      Error (Some (Status.ProtocolError, "control frame too big"))
  | Ping -> Ok (Some {frame with header= {header with opcode= Pong}}, None)
  | Close ->
      let status =
        Option.value ~default:Status.NormalClosure (Status.of_payload payload)
      in
      Log.debug (fun m ->
          m "Remote endpoint closed connection (%a)" Status.pp status) ;
      Error None
  | Pong -> (
    match Bigstringaf.length payload with
    | 0 ->
        st.on_pong None ;
        Log.debug (fun m -> m "<- PONG") ;
        Ok (None, None)
    | _ ->
        ( try
            let now = Time_ns_unix.now () in
            let old = Time_ns_unix.of_string (Bigstring.to_string payload) in
            let diff = Time_ns_unix.diff now old in
            Log.debug (fun m -> m "<- PONG %a" Time_ns_unix.Span.pp diff) ;
            st.on_pong (Some diff)
          with _ -> () ) ;
        Ok (None, None) )
  | Text | Binary -> Ok (None, Some frame)
  | Continuation -> assert false
  | Ctrl _ | Nonctrl _ ->
      Error (Some (Status.UnsupportedExtension, "unsupported extension"))

let heartbeat w span =
  let write_ping () =
    Log_async.debug (fun m -> m "-> PING")
    >>= fun () ->
    let ping = Frame.String.pingf "%a" Time_ns_unix.pp (Time_ns_unix.now ()) in
    Fastws_async_raw.write_frame_if_open w ping in
  let start = Time_ns_unix.(add (now ()) span) in
  let stop = Pipe.closed w in
  Clock_ns.run_at_intervals' ~continue_on_error:false ~start ~stop span
    write_ping

let write_close st w fr =
  ( match Status.of_payload fr.Frame.payload with
  | Some status when Status.is_unknown status ->
      Bigstringaf.set_int16_be fr.payload 0 Status.(to_int ProtocolError)
  | _ -> () ) ;
  match st.conn_state with
  | `Closed -> Deferred.unit
  | `Closing ->
      st.conn_state <- `Closed ;
      write_frame_if_open w fr
  | `Open ->
      st.conn_state <- `Closing ;
      write_frame_if_open w fr

let decr_conn_state st =
  st.conn_state <-
    ( match st.conn_state with
    | `Open -> `Closing
    | `Closing -> `Closed
    | `Closed -> `Closed )

let check_hdr_before_reassemble {header; payload= _} =
  Log.debug (fun m -> m "%a" Header.pp header) ;
  header.rsv land 3 = 0 && Opcode.is_std header.opcode

exception Closing of Frame.t

let closing fr = raise (Closing fr)

let mk_r3 of_frame st r2 w2 =
  let close_all () = Pipe.close_read r2 ; Pipe.close w2 in
  let reassemble_and_process ret t =
    match check_hdr_before_reassemble t with
    | false ->
        closing
        @@ Frame.String.closef ~status:Status.ProtocolError "invalid header"
    | _ -> (
      match reassemble st t with
      | Error msg ->
          closing
          @@ Frame.String.close
               ~status:
                 ( Status.ProtocolError,
                   Some ("\000\000" ^ Error.to_string_hum msg) )
               ()
      | Ok `Continue -> Deferred.unit
      | Ok (`Frame fr) -> (
          Log.debug (fun m -> m "<- %a" Frame.pp fr) ;
          match r3_of_r2 st fr with
          | Error None ->
              (* got a close frame *)
              decr_conn_state st ; closing fr
          | Error (Some (status, msg)) ->
              closing @@ Frame.String.closef ~status "%s" msg
          | Ok (for_w2, for_r3) ->
              Option.fold for_w2 ~init:Deferred.unit ~f:(fun _ ->
                  write_frame_if_open w2)
              >>| fun () ->
              Option.iter ~f:(fun fr -> Queue.enqueue ret (of_frame fr)) for_r3
          ) ) in
  let transferf q =
    let ret = Queue.create () in
    try_with ~extract_exn:true (fun () ->
        Deferred.Queue.iter q ~f:(reassemble_and_process ret))
    >>= function
    | Ok () -> return ret
    | Error (Closing fr) ->
        write_close st w2 fr >>| fun () -> close_all () ; Queue.create ()
    | Error exn -> raise exn in
  Pipe.create_reader ~close_on_exception:false (fun to_r3 ->
      Pipe.transfer' r2 to_r3 ~f:transferf)

let mk_w3 to_frame w2 =
  Pipe.create_writer (fun from_w3 ->
      Pipe.transfer from_w3 w2 ~f:(fun pl ->
          let {Frame.header; payload} = to_frame pl in
          { header;
            payload=
              (if Bigstring.length payload = 0 then None else Some payload) }))

type ('r, 'w) t = {r: 'r Pipe.Reader.t; w: 'w Pipe.Writer.t}

let create r w = {r; w}

let connect ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb url r w
    of_frame to_frame =
  connect ?extra_headers ?extensions ?protocols ?monitor url r w
  >>|? fun (exts, r2, w2) ->
  let permessage_deflate =
    List.Assoc.mem ~equal:String.equal exts "permessage-deflate" in
  let st = create_st ~permessage_deflate ?on_pong () in
  Option.iter hb ~f:(heartbeat w2) ;
  let r3 = mk_r3 of_frame st r2 w2 in
  let w3 = mk_w3 to_frame w2 in
  (Pipe.closed r3 >>> fun () -> Pipe.close_read r2) ;
  ( Deferred.all_unit [Pipe.closed w3; Pipe.closed r3]
  >>> fun () -> Pipe.close w2 ) ;
  create r3 w3

let with_connection ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb
    url r w of_frame to_frame f =
  connect ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb url r w
    of_frame to_frame
  >>=? fun {r= r3; w= w3} ->
  Monitor.protect
    (fun () -> f r3 w3 >>| fun res -> Ok res)
    ~finally:(fun () ->
      Log_async.debug (fun m -> m "Fastws_async.with_connection: finally")
      >>= fun () ->
      Pipe.close_read r3 ;
      Pipe.close w3 ;
      Deferred.all_unit
        [ (* Deferred.ignore_m (Pipe.upstream_flushed r3); *)
          (* Deferred.ignore_m (Pipe.downstream_flushed w3); *) Deferred.unit ])

let of_frame_s {Frame.payload; _} = Bigstring.to_string payload
let to_frame_s msg = Frame.String.textf "%s" msg

let connect_or_result ?on_pong ?extra_headers ?extensions ?protocols ?monitor
    ?hb of_frame to_frame url =
  Async_uri.connect url
  >>= fun {r; w; _} ->
  Monitor.try_with ~extract_exn:true (fun () ->
      connect ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb url r
        w of_frame to_frame)
  >>= function
  | Error exn -> Writer.close w >>= fun () -> raise exn | Ok x -> return x

let connect_or_error ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb
    of_frame to_frame url =
  Async_uri.connect url
  >>= fun {r; w; _} ->
  Monitor.try_with ~extract_exn:true (fun () ->
      connect ?on_pong ?extra_headers ?extensions ?protocols ?monitor ?hb url r
        w of_frame to_frame)
  >>= function
  | Error exn -> Writer.close w >>= fun () -> raise exn
  | Ok x -> to_or_error (return x)

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
