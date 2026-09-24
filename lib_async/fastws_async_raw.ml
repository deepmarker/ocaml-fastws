(*---------------------------------------------------------------------------
   Copyright (c) 2020 DeepMarker. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpun
open Fastws

type err =
  [ `Connection_error of Client_connection.error
  | `Invalid_response of Response.t
  | `Timeout
  ]

let to_error _x = Error.createf "xxx"
let to_or_error = Deferred.Result.map_error ~f:(fun _x -> Error.createf "xxx")

let merge_headers h1 h2 =
  Headers.fold ~init:h2 ~f:(fun k v a -> Headers.add_unless_exists a k v) h1
;;

let response_handler src w iv nonce crypto r _body =
  let module Crypto = (val crypto : CRYPTO) in
  Logs.debug ~src (fun m -> m "%a" Response.pp_hum r);
  let upgrade_hdr = Option.map ~f:String.lowercase (Headers.get r.headers "upgrade") in
  let sec_ws_accept_hdr = Headers.get r.headers "sec-websocket-accept" in
  let expected_sec =
    let open Digestif.SHA1 in
    digest_string (nonce ^ websocket_uuid) |> to_raw_string |> Base64.encode_exn
  in
  match r.version, r.status, upgrade_hdr, sec_ws_accept_hdr with
  | { major = 1; minor = 1 }, `Switching_protocols, Some "websocket", Some v
    when String.equal v expected_sec -> Ivar.fill_if_empty iv (Ok r)
  | _ ->
    don't_wait_for (Writer.close w);
    Logs.err ~src (fun m -> m "Invalid response %a" Response.pp_hum r);
    Ivar.fill_if_empty iv (Error (`Invalid_response r))
;;

let write_iovecs src w iovecs =
  let nbWritten =
    List.fold_left iovecs ~init:0 ~f:(fun a ({ IOVec.len; _ } as iovec) ->
      (try Writer.schedule_iovec w (Obj.magic iovec) with
       | exn -> Logs.err ~src (fun m -> m "%a" Exn.pp exn));
      a + len)
  in
  `Ok nbWritten
;;

let rec flush_req src conn w =
  match Client_connection.next_write_operation conn with
  | `Write iovecs ->
    Client_connection.report_write_result conn (write_iovecs src w iovecs);
    flush_req src conn w
  | `Yield -> Client_connection.yield_writer conn (fun () -> flush_req src conn w)
  | `Close _ -> ()
;;

let rec read_response conn r =
  match Client_connection.next_read_operation conn with
  | `Yield | `Close -> Deferred.unit
  | `Read ->
    Reader.read_one_chunk_at_a_time r ~handle_chunk:(fun buf ~pos ~len ->
      let nb_read = Client_connection.read conn buf ~off:pos ~len in
      return (`Stop_consumed ((), nb_read)))
    >>= (function
     | `Eof ->
       let buf = Bigstringaf.empty in
       ignore (Client_connection.read_eof conn buf ~off:0 ~len:0);
       Deferred.unit
     | `Eof_with_unconsumed_data buf ->
       let len = String.length buf in
       let buf = Bigstringaf.of_string ~off:0 ~len buf in
       ignore (Client_connection.read_eof conn buf ~off:0 ~len);
       Deferred.unit
     | `Stopped () -> read_response conn r)
;;

let serialize src stream w =
  Faraday_async.serialize
    stream
    ~yield:(fun _ -> Scheduler.yield ())
    ~writev:(fun iov -> return (write_iovecs src w iov))
;;

let xor_char a b = Char.(unsafe_of_int (to_int a lxor to_int b))

let xormask ~mask buf =
  let open Bytes in
  for i = 0 to length buf - 1 do
    set buf i (xor_char (get buf i) mask.[i mod 4])
  done
;;

let xormask_to_faraday ?mask buf t =
  match mask with
  | None -> Faraday.write_string t buf
  | Some mask ->
    String.iteri buf ~f:(fun i c -> Faraday.write_char t (xor_char c mask.[i mod 4]))
;;

let write_payload ?mask src w buf =
  let serializer = Faraday.create (String.length buf + 6) in
  xormask_to_faraday ?mask buf serializer;
  Faraday.close serializer;
  serialize src serializer w
;;

let write_frame mask src w ({ Frame.header; payload } as frame) =
  let serializer = Faraday.create 6 in
  let h =
    match mask with
    (* A server never masks (RFC 6455, section 5.1), whatever the frame
       carries: a frame built from one the client sent -- the pong answering
       its ping -- still holds the client's masking key. *)
    | false -> { header with mask = None }
    | true ->
      let mask = Crypto.(to_string (generate 4)) in
      { header with mask = Some mask }
  in
  Logs.debug ~src (fun m -> m "-> %a" Frame.pp { frame with header = h });
  Header.serialize serializer h;
  Faraday.close serializer;
  serialize src serializer w
  >>= fun () ->
  match payload with
  | "" -> Deferred.unit
  | payload -> write_payload ?mask:h.mask src w payload
;;

module St = struct
  type t =
    { h : Header.t
    ; payload : bytes
    ; mutable pos : int
    }

  let create h =
    let payload = Bytes.create h.Header.length in
    { h; payload; pos = 0 }
  ;;

  let write w { h = header; payload; _ } =
    Option.iter header.mask ~f:(fun mask -> xormask ~mask payload);
    let payload = Bytes.unsafe_to_string ~no_mutation_while_string_reachable:payload in
    Pipe.write_without_pushback_if_open w { Frame.header; payload }
  ;;
end

module ChunkSt = struct
  type t =
    { mutable current_header : St.t option
    ; mutable consumed : int
    }
end

let%trace read_payload buf ~pos ~len ~(state : ChunkSt.t) ~w (st : St.t) =
  let wanted_len = Bytes.length st.payload - st.pos in
  let will_read = min (len - state.consumed) wanted_len in
  Bigstring.To_bytes.blit
    ~src:buf
    ~src_pos:(pos + state.consumed)
    ~dst:st.payload
    ~dst_pos:st.pos
    ~len:will_read;
  st.pos <- st.pos + will_read;
  state.consumed <- state.consumed + will_read;
  let missing_len = wanted_len - will_read in
  if missing_len > 0
  then `Consumed (state.consumed, `Need missing_len)
  else if Pipe.is_closed w
  then `Stop ()
  else (
    St.write w st;
    state.current_header <- None;
    `Continue)
;;

let%trace read_header _src buf ~pos ~len ~(state : ChunkSt.t) ~w =
  match len - state.consumed with
  | 0 -> `Continue
  | 1 -> `Consumed (state.consumed, `Need 2)
  | _ ->
    (match Header.parse buf ~pos:(pos + state.consumed) ~len:(len - state.consumed) with
     | `Need n -> `Consumed (state.consumed, `Need n)
     | `Ok (h, read) ->
       state.consumed <- state.consumed + read;
       if h.length = 0
       then
         if Pipe.is_closed w
         then `Stop ()
         else (
           Pipe.write_without_pushback w { Frame.header = h; payload = "" };
           `Continue)
       else (
         (* check header validity *)
         (* Logs.debug ~src (fun m -> m "%a" Header.pp h) ; *)
         let valid =
           h.rsv land 3 = 0
           && Opcode.is_std h.opcode
           && h.length > 0
           && h.length < 100 * 1024 * 1024
         in
         if not valid
         then raise_s [%message "invalid header" ~hdr:(h : Header.t)]
         else state.current_header <- Some (St.create h);
         `Continue))
;;

let%trace handle_chunk src w =
  let state = { ChunkSt.current_header = None; consumed = 0 } in
  fun buf ~pos ~len ->
    let rec process_loop () =
      if state.consumed >= len
      then `Continue
      else (
        match state.current_header with
        | None ->
          (match read_header src buf ~pos ~len ~state ~w with
           | `Continue -> process_loop ()
           | other -> other)
        | Some st ->
          (match read_payload buf ~pos ~len ~state ~w st with
           | `Continue -> process_loop ()
           | other -> other))
    in
    state.consumed <- 0;
    match process_loop () with
    | exception _ -> return (`Stop ())
    | result -> Pipe.pushback w >>= fun () -> return result
;;

let initialize
      ?monitor
      ?timeout
      ?(extra_headers = Headers.empty)
      ?(extensions = [ "permessage-deflate", None ])
      ?protocols
      src
      url
      r
      w
  =
  let extensions =
    match extensions with
    | [] -> None
    | _ -> Some extensions
  in
  let nonce = Base64.encode_exn Crypto.(generate 16 |> to_string) in
  let headers =
    match Uri.host url, Uri.port url with
    | Some h, Some p -> Headers.add extra_headers "Host" (h ^ ":" ^ Int.to_string p)
    | Some h, None -> Headers.add extra_headers "Host" h
    | _ -> extra_headers
  in
  let headers = merge_headers headers (Fastws.headers ?extensions ?protocols nonce) in
  let req = Request.create ~headers `GET (Uri.path_and_query url) in
  let ok = Ivar.create () in
  let error_handler e =
    don't_wait_for (Writer.close w);
    Ivar.fill_exn ok (Error (`Connection_error e))
  in
  let response_handler = response_handler src w ok nonce (module Crypto) in
  let conn = Client_connection.create () in
  let _body =
    Client_connection.request
      ~flush_headers_immediately:true
      conn
      req
      ~error_handler
      ~response_handler
  in
  flush_req src conn w;
  don't_wait_for (Scheduler.within' ?monitor (fun () -> read_response conn r));
  Logs_async.debug ~src (fun m -> m "%a" Request.pp_hum req)
  >>= fun () ->
  let timeout =
    match timeout with
    | None -> Deferred.never ()
    | Some timeout -> Clock.after timeout >>| fun () -> Error `Timeout
  in
  Deferred.any [ Ivar.read ok; timeout ]
;;

let mk_r2 src r w =
  (* This should return when the connection is closed. But in
     practice, it does not work well, i.e. the connection can be dead
     and this does not return. *)
  (* if w is closed, then [handle_chunk] will complete and [finally]
     below will be triggered. *)
  (* handle chunk does not raise, will return [Stop ()] on read
     error. *)
  let handle_chunk = handle_chunk src w in
  Monitor.protect
    ~finally:(fun () -> Reader.close r)
    (fun () -> Reader.read_one_chunk_at_a_time r ~handle_chunk |> Deferred.ignore_m)
;;

let mk_w2 ?monitor mask src w r =
  let downstream_flushed () =
    match Pipe.is_closed r with
    | true -> return `Reader_closed (* Not sure if this is correct. *)
    | false -> Deferred.any_unit Writer.[ flushed w; close_finished w ] >>| fun () -> `Ok
  in
  let consumer = Pipe.add_consumer r ~downstream_flushed in
  (* Will terminate if any of the following returns. *)
  let on_msg q =
    Deferred.Queue.iter q ~how:`Sequential ~f:(write_frame mask src w)
    >>= fun () ->
    (* flush writer *)
    Writer.flushed_or_failed_with_result w
    >>= function
    | Flushed _ts -> Deferred.unit
    | _ ->
      (* The underlying writer failed to flush: the connection is dead.
         Stop the write loop cleanly by closing the pipe reader, which lets
         [Pipe.iter'] complete and triggers the [Writer.close w] finally.
         Raising here would escape to the monitor in effect when
         [Pipe.create_writer] was called (not [?monitor]) and take down the
         whole process. *)
      Pipe.close_read r;
      Deferred.unit
  in
  (* Writer guaranteed to be closed after this. *)
  Monitor.protect
    ~finally:(fun () -> Writer.close w)
    (fun () ->
       Deferred.any_unit
         [ Writer.close_started w
         ; Writer.close_finished w
         ; Writer.stopped_permanently w
         ; (Monitor.detach_and_get_next_error (Writer.monitor w)
            >>| fun exn -> Option.iter monitor ~f:(fun m -> Monitor.send_exn m exn))
         ; Pipe.iter' ~continue_on_error:false ~flushed:(Consumer consumer) r ~f:on_msg
         ])
;;

let parse_extension_value s =
  (* Parse: extension-name [; param=value]* *)
  match String.lsplit2 s ~on:';' with
  | None -> String.strip s, []
  | Some (name, params) ->
    let parse_param p =
      match String.lsplit2 (String.strip p) ~on:'=' with
      | None -> String.strip p, None
      | Some (k, v) -> String.strip k, Some (String.strip v)
    in
    let params = String.split params ~on:';' |> List.map ~f:parse_param in
    String.strip name, params
;;

let get_extensions (headers : Headers.t) =
  Headers.fold headers ~init:[] ~f:(fun k v acc ->
    if String.Caseless.equal k "sec-websocket-extensions"
    then (
      (* Split by comma for multiple extensions in one header *)
      let exts = String.split v ~on:',' |> List.map ~f:parse_extension_value in
      exts @ acc)
    else acc)
;;

let set_extensions exts =
  match exts with
  | [] -> Headers.empty
  | _ ->
    let format_param (k, v) =
      match v with
      | None -> k
      | Some value -> k ^ "=" ^ value
    in
    let format_extension (name, params) =
      match params with
      | [] -> name
      | _ ->
        let params_str = String.concat ~sep:"; " (List.map params ~f:format_param) in
        name ^ "; " ^ params_str
    in
    let value = String.concat ~sep:", " (List.map exts ~f:format_extension) in
    Headers.of_list [ "sec-websocket-extensions", value ]
;;

let connect ?extra_headers ?extensions ?protocols ?timeout ?monitor src url r w =
  initialize ?timeout ?extra_headers ?extensions ?protocols src url r w
  >>| function
  | Error _ as res ->
    (* Free resources! *)
    don't_wait_for (Reader.close r);
    don't_wait_for (Writer.close w);
    res
  | Ok resp ->
    let exts = get_extensions resp.headers in
    Result.return
      ( exts
      , Pipe.create_reader ~close_on_exception:false (mk_r2 src r)
      , Pipe.create_writer (mk_w2 ?monitor true src w) )
;;

let of_initialized ?monitor ?(mask = false) src r w =
  ( Pipe.create_reader ~close_on_exception:false (mk_r2 src r)
  , Pipe.create_writer (mk_w2 ?monitor mask src w) )
;;

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
