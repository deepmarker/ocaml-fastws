(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf
open Core
open Async
open Fastws

let src = Logs.Src.create "fastws.async.raw"

module Log = (val Logs.src_log src : Logs.LOG)

module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

type t = Header of Header.t | Payload of Bigstring.t [@@deriving sexp_of]

let is_header = function Header _ -> true | _ -> false

let pp_client_connection_error ppf (e : Client_connection.error) =
  match e with
  | `Exn e -> Format.fprintf ppf "Exception %a" Exn.pp e
  | `Invalid_response_body_length resp ->
      Format.fprintf ppf "Invalid response body length %a" Response.pp_hum resp
  | `Malformed_response msg -> Format.fprintf ppf "Malformed response %s" msg

let write_frame w { Frame.header; payload } =
  Pipe.write w (Header header) >>= fun () ->
  match Bigstring.length payload with
  | 0 -> Deferred.unit
  | _ -> Pipe.write w (Payload payload)

let write_frame_if_open w { Frame.header; payload } =
  Pipe.write_if_open w (Header header) >>= fun () ->
  match Bigstring.length payload with
  | 0 -> Deferred.unit
  | _ -> Pipe.write_if_open w (Payload payload)

let merge_headers h1 h2 =
  Headers.fold ~init:h2 ~f:(fun k v a -> Headers.add_unless_exists a k v) h1

let response_handler iv nonce crypto r _body =
  let module Crypto = (val crypto : CRYPTO) in
  Log.debug (fun m -> m "%a" Response.pp_hum r);
  let upgrade_hdr =
    Option.map ~f:String.lowercase (Headers.get r.headers "upgrade")
  in
  let sec_ws_accept_hdr = Headers.get r.headers "sec-websocket-accept" in
  let expected_sec =
    Base64.encode_exn
      Crypto.(sha_1 (of_string (nonce ^ websocket_uuid)) |> to_string)
  in
  match (r.version, r.status, upgrade_hdr, sec_ws_accept_hdr) with
  | { major = 1; minor = 1 }, `Switching_protocols, Some "websocket", Some v
    when String.equal v expected_sec ->
      Ivar.fill_if_empty iv (Ok r)
  | _ ->
      Log.err (fun m -> m "Invalid response %a" Response.pp_hum r);
      Ivar.fill_if_empty iv
        (Format.kasprintf Or_error.error_string "%a" Response.pp_hum r)

let write_iovecs w iovecs =
  let nbWritten =
    List.fold_left iovecs ~init:0 ~f:(fun a ({ IOVec.len; _ } as iovec) ->
        Writer.schedule_iovec w (Obj.magic iovec);
        a + len)
  in
  `Ok nbWritten

let rec flush_req conn w =
  match Client_connection.next_write_operation conn with
  | `Write iovecs ->
      Client_connection.report_write_result conn (write_iovecs w iovecs);
      flush_req conn w
  | `Yield -> Client_connection.yield_writer conn (fun () -> flush_req conn w)
  | `Close _ -> ()

let rec read_response conn r =
  match Client_connection.next_read_operation conn with
  | `Close -> Deferred.unit
  | `Read -> (
      Reader.read_one_chunk_at_a_time r ~handle_chunk:(fun buf ~pos ~len ->
          let nb_read = Client_connection.read conn buf ~off:pos ~len in
          return (`Stop_consumed ((), nb_read)))
      >>= function
      | `Eof | `Eof_with_unconsumed_data _ -> raise Exit
      | `Stopped () -> read_response conn r )

let serialize stream w =
  Faraday_async.serialize stream
    ~yield:(fun _ -> Scheduler.yield ())
    ~writev:(fun iov -> return (write_iovecs w iov))

let foldf w (a : Fastws.Header.t option) = function
  | Header t ->
      let serializer = Faraday.create 6 in
      let mask = Crypto.(to_string (generate 4)) in
      let h = { t with mask = Some mask } in
      Header.serialize serializer h;
      Faraday.close serializer;
      serialize serializer w >>= fun () ->
      don't_wait_for
        ( Writer.flushed w >>= fun () ->
          Log_async.debug (fun m -> m "-> %a" Header.pp t) );
      return (Some h)
  | Payload buf -> (
      match a with
      | Some { mask = Some mask; _ } ->
          let serializer = Faraday.create (Bigstring.length buf + 6) in
          Header.xormask ~mask buf;
          Faraday.write_bigstring serializer buf;
          Faraday.close serializer;
          Header.xormask ~mask buf;
          serialize serializer w >>= fun () ->
          don't_wait_for
            ( Writer.flushed w >>= fun () ->
              Log_async.debug (fun m ->
                  m "-> %s"
                    Bigstring.(
                      to_string buf ~pos:0 ~len:(min 4096 (length buf)))) );
          return None
      | _ -> failwith "current header must exist" )

let mk_w2 ~monitor:_ w =
  Pipe.create_writer (fun r ->
      let downstream_flushed () =
        match Pipe.is_closed r with
        | true -> return `Reader_closed (* Not sure if this is correct. *)
        | false ->
            Deferred.any_unit Writer.[ flushed w; close_started w ]
            >>| fun () -> `Ok
      in
      let consumer = Pipe.add_consumer r ~downstream_flushed in
      Deferred.any_unit
        [
          Writer.close_started w;
          Pipe.fold' ~flushed:(Consumer consumer) r ~init:None ~f:(fun init q ->
              Deferred.Queue.fold q ~init ~f:(foldf w))
          |> Deferred.ignore_m;
        ])

type st = { h : Header.t; payload : Bigstring.t; mutable pos : int }

let create_st h =
  let payload = Bigstring.create h.Header.length in
  { h; payload; pos = 0 }

let write_st w { h; payload; _ } =
  Pipe.write w (Header h) >>= fun () -> Pipe.write w (Payload payload)

let handle_chunk w =
  let current_header = ref None in
  let consumed = ref 0 in
  let rec read_payload buf ~pos ~len =
    assert (Option.is_some !current_header);
    let st = Option.value_exn !current_header in
    let wanted_len = Bigstring.length st.payload - st.pos in
    let will_read = min (len - !consumed) wanted_len in
    Bigstring.blit ~src:buf ~src_pos:(pos + !consumed) ~dst:st.payload
      ~dst_pos:st.pos ~len:will_read;
    st.pos <- st.pos + will_read;
    consumed := !consumed + will_read;
    let missing_len = wanted_len - will_read in
    if missing_len > 0 then (
      assert (missing_len > len - !consumed);
      return (`Consumed (!consumed, `Need missing_len)) )
    else
      match Pipe.is_closed w with
      | true -> return (`Stop ())
      | false ->
          write_st w st >>= fun () ->
          current_header := None;
          read_header buf ~pos ~len
  and read_header buf ~pos ~len =
    assert (Option.is_none !current_header);
    match len - !consumed with
    | 0 -> return `Continue
    | 1 -> return (`Consumed (!consumed, `Need 2))
    | _ -> (
        match
          Header.parse buf ~pos:(pos + !consumed) ~len:(len - !consumed)
        with
        | `Need n -> return (`Consumed (!consumed, `Need n))
        | `Ok (h, read) ->
            consumed := !consumed + read;
            if h.length = 0 then
              match Pipe.is_closed w with
              | true -> return (`Stop ())
              | false ->
                  Pipe.write w (Header h) >>= fun () ->
                  read_header buf ~pos ~len
            else (
              current_header := Some (create_st h);
              read_payload buf ~pos ~len ) )
  in
  fun buf ~pos ~len ->
    (* Log_async.debug (fun m -> m "handle_chunk") >>= fun () -> *)
    consumed := 0;
    match !current_header with
    | None -> read_header buf ~pos ~len
    | Some _ -> read_payload buf ~pos ~len

let mk_r2 ~monitor r =
  Pipe.create_reader ~close_on_exception:false (fun to_r2 ->
      Scheduler.within' ~monitor (fun () ->
          let handle_chunk = handle_chunk to_r2 in
          Monitor.protect
            (fun () -> Reader.read_one_chunk_at_a_time r ~handle_chunk)
            ~finally:(fun () ->
              Log_async.debug (fun m ->
                  m "Fastws_async_raw.mk_client_read: finally")
              >>= fun () ->
              Pipe.close to_r2;
              Reader.close r)
          |> Deferred.ignore_m))

let initialize ?timeout ?(extra_headers = Headers.empty) url r w =
  let nonce = Base64.encode_exn Crypto.(generate 16 |> to_string) in
  let headers =
    match (Uri.host url, Uri.port url) with
    | Some h, Some p ->
        Headers.add extra_headers "Host" (h ^ ":" ^ Int.to_string p)
    | Some h, None -> Headers.add extra_headers "Host" h
    | _ -> extra_headers
  in
  let headers = merge_headers headers (Fastws.headers nonce) in
  let req = Request.create ~headers `GET (Uri.path_and_query url) in
  let ok = Ivar.create () in
  let error_handler e =
    Ivar.fill ok
      (Format.kasprintf Or_error.error_string "%a" pp_client_connection_error e)
  in
  let response_handler = response_handler ok nonce (module Crypto) in
  let _body, conn =
    Client_connection.request req ~error_handler ~response_handler
  in
  flush_req conn w;
  don't_wait_for (read_response conn r);
  Log_async.debug (fun m -> m "%a" Request.pp_hum req) >>= fun () ->
  let timeout =
    match timeout with
    | None -> Deferred.never ()
    | Some timeout ->
        Clock.after timeout >>| fun () ->
        Format.kasprintf Or_error.error_string "Timeout %a" Time.Span.pp timeout
  in
  Deferred.any [ Ivar.read ok; timeout ] >>= function
  | Error e -> Error.raise e
  | Ok v -> Deferred.return v

let connect ?version ?options ?socket ?(crypto = (module Crypto : CRYPTO))
    ?extra_headers ?buffer_age_limit ?interrupt ?reader_buffer_size
    ?writer_buffer_size ?timeout url =
  let module Crypto = (val crypto : CRYPTO) in
  Async_uri.connect ?version ?options ?socket ?buffer_age_limit ?interrupt
    ?reader_buffer_size ?writer_buffer_size ?timeout url
  >>= fun { r; w; _ } ->
  initialize ?timeout ?extra_headers url r w >>| fun _resp ->
  let monitor = Monitor.create () in
  let r2 = mk_r2 ~monitor r in
  let w2 = mk_w2 ~monitor w in
  (* don't_wait_for
   *   ( Reader.close_finished r >>= fun () ->
   *     Log_async.debug (fun m -> m "reader closed") ); *)
  let log_exn exn = Log.err (fun m -> m "%a" Exn.pp exn) in
  Monitor.detach_and_iter_errors monitor ~f:log_exn;
  Monitor.detach_and_iter_errors (Writer.monitor w) ~f:log_exn;
  (r2, w2)

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
