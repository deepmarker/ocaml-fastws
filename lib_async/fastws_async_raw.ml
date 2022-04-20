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

type t = { header : Header.t; payload : Bigstring.t option }
[@@deriving sexp_of]

type err =
  [ `Connection_error of (Client_connection.error[@sexp.opaque])
  | `Invalid_response of (Response.t[@sexp.opaque])
  | `Timeout ]
[@@deriving sexp_of]

let to_error x = Error.create_s (sexp_of_err x)

let to_or_error =
  Deferred.Result.map_error ~f:(fun x -> Error.create_s (sexp_of_err x))

let is_header { payload; _ } = Option.is_none payload

let write_frame_if_open w { Frame.header; payload } =
  Pipe.write_if_open w { header; payload = Some payload }

let merge_headers h1 h2 =
  Headers.fold ~init:h2 ~f:(fun k v a -> Headers.add_unless_exists a k v) h1

let response_handler w iv nonce crypto r _body =
  let module Crypto = (val crypto : CRYPTO) in
  Log.debug (fun m -> m "%a" Response.pp_hum r);
  let upgrade_hdr =
    Option.map ~f:String.lowercase (Headers.get r.headers "upgrade")
  in
  let sec_ws_accept_hdr = Headers.get r.headers "sec-websocket-accept" in
  let expected_sec =
    let open Digestif.SHA1 in
    digest_string (nonce ^ websocket_uuid) |> to_raw_string |> Base64.encode_exn
  in
  match (r.version, r.status, upgrade_hdr, sec_ws_accept_hdr) with
  | { major = 1; minor = 1 }, `Switching_protocols, Some "websocket", Some v
    when String.equal v expected_sec ->
      Ivar.fill_if_empty iv (Ok r)
  | _ ->
      don't_wait_for (Writer.close w);
      Log.err (fun m -> m "Invalid response %a" Response.pp_hum r);
      Ivar.fill_if_empty iv (Error (`Invalid_response r))

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
      | `Eof ->
          let buf = Bigstringaf.create 0 in
          ignore (Client_connection.read_eof conn buf ~off:0 ~len:0);
          Deferred.unit
      | `Eof_with_unconsumed_data buf ->
          let len = String.length buf in
          let buf = Bigstringaf.of_string ~off:0 ~len buf in
          ignore (Client_connection.read_eof conn buf ~off:0 ~len);
          Deferred.unit
      | `Stopped () -> read_response conn r)

let serialize stream w =
  Faraday_async.serialize stream
    ~yield:(fun _ -> Scheduler.yield ())
    ~writev:(fun iov -> return (write_iovecs w iov))

let iterf w { header; payload } =
  let read_header t =
    let serializer = Faraday.create 6 in
    let mask = Crypto.(to_string (generate 4)) in
    let (h : Header.t) = { t with mask = Some mask } in
    Header.serialize serializer h;
    Faraday.close serializer;
    serialize serializer w >>= fun () ->
    don't_wait_for
      ( Writer.flushed w >>= fun () ->
        Log_async.debug (fun m -> m "-> %a" Header.pp t) );
    return mask
  in
  let read_payload mask buf =
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
              Bigstring.(to_string buf ~pos:0 ~len:(min 4096 (length buf)))) );
    Deferred.unit
  in
  read_header header >>= fun mask ->
  Option.value_map payload ~default:Deferred.unit ~f:(read_payload mask)

let mk_w2 ?monitor w =
  Pipe.create_writer (fun r ->
      don't_wait_for (Pipe.closed r >>= fun () -> Writer.close w);
      let downstream_flushed () =
        match Pipe.is_closed r with
        | true -> return `Reader_closed (* Not sure if this is correct. *)
        | false ->
            Deferred.any_unit Writer.[ flushed w; close_finished w ]
            >>| fun () -> `Ok
      in
      let consumer = Pipe.add_consumer r ~downstream_flushed in
      Deferred.any_unit
        [
          Writer.close_started w;
          Writer.close_finished w;
          ( Monitor.detach_and_get_next_error (Writer.monitor w) >>| fun exn ->
            Option.iter monitor ~f:(fun m -> Monitor.send_exn m exn) );
          Pipe.iter' ~flushed:(Consumer consumer) r
            ~f:(Deferred.Queue.iter ~f:(iterf w))
          |> Deferred.ignore_m;
        ])

type st = { h : Header.t; payload : Bigstring.t; mutable pos : int }

let create_st h =
  let payload = Bigstring.create h.Header.length in
  { h; payload; pos = 0 }

let write_st w { h = header; payload; _ } =
  Pipe.write_without_pushback w { header; payload = Some payload }

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
      return (`Consumed (!consumed, `Need missing_len)))
    else
      match Pipe.is_closed w with
      | true -> return (`Stop ())
      | false ->
          write_st w st;
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
            if h.length = 0 then (
              match Pipe.is_closed w with
              | true -> return (`Stop ())
              | false ->
                  Pipe.write_without_pushback w { header = h; payload = None };
                  read_header buf ~pos ~len)
            else (
              current_header := Some (create_st h);
              read_payload buf ~pos ~len))
  in
  fun buf ~pos ~len ->
    (* Log_async.debug (fun m -> m "handle_chunk") >>= fun () -> *)
    consumed := 0;
    (match !current_header with
    | None -> read_header buf ~pos ~len
    | Some _ -> read_payload buf ~pos ~len)
    >>= fun ret ->
    Pipe.pushback w >>= fun () -> return ret

let mk_r2 r =
  Pipe.create_reader ~close_on_exception:false (fun w ->
      don't_wait_for (Pipe.closed w >>= fun () -> Reader.close r);
      let handle_chunk = handle_chunk w in
      Reader.read_one_chunk_at_a_time r ~handle_chunk |> Deferred.ignore_m)

let initialize ?monitor ?timeout ?(extra_headers = Headers.empty)
    ?(extensions = [ ("permessage-deflate", None) ]) ?protocols url r w =
  let extensions = match extensions with [] -> None | _ -> Some extensions in
  let nonce = Base64.encode_exn Crypto.(generate 16 |> to_string) in
  let headers =
    match (Uri.host url, Uri.port url) with
    | Some h, Some p ->
        Headers.add extra_headers "Host" (h ^ ":" ^ Int.to_string p)
    | Some h, None -> Headers.add extra_headers "Host" h
    | _ -> extra_headers
  in
  let headers =
    merge_headers headers (Fastws.headers ?extensions ?protocols nonce)
  in
  let req = Request.create ~headers `GET (Uri.path_and_query url) in
  let ok = Ivar.create () in
  let error_handler e =
    don't_wait_for (Writer.close w);
    Ivar.fill ok (Error (`Connection_error e))
  in
  let response_handler = response_handler w ok nonce (module Crypto) in
  let _body, conn =
    Client_connection.request req ~error_handler ~response_handler
  in
  flush_req conn w;
  don't_wait_for (Scheduler.within' ?monitor (fun () -> read_response conn r));
  Log_async.debug (fun m -> m "%a" Request.pp_hum req) >>= fun () ->
  let timeout =
    match timeout with
    | None -> Deferred.never ()
    | Some timeout -> Clock.after timeout >>| fun () -> Error `Timeout
  in
  Deferred.any [ Ivar.read ok; timeout ]

let connect ?extra_headers ?extensions ?protocols ?timeout ?monitor url r w =
  initialize ?timeout ?extra_headers ?extensions ?protocols url r w
  >>|? fun resp ->
  let exts =
    Option.value_map ~default:[] ~f:extension_parser
      (Headers.get resp.headers "sec-websocket-extensions")
  in
  (exts, mk_r2 r, mk_w2 ?monitor w)

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
