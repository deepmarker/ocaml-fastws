(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpaf

open Fastws

let src =
  Logs.Src.create "fastws.async"

let merge_headers h1 h2 =
  Headers.fold ~init:h2 ~f:begin fun k v a ->
    Headers.add_unless_exists a k v
  end h1

let response_handler iv nonce crypto
    ({ Response.version ; status ; headers ; _ } as response) _body =
  let module Crypto = (val crypto : CRYPTO) in
  Logs.debug ~src (fun m -> m "%a" Response.pp_hum response) ;
  let upgrade_hdr = Option.map ~f:String.lowercase (Headers.get headers "upgrade") in
  let sec_ws_accept_hdr = Headers.get headers "sec-websocket-accept" in
  let expected_sec =
    Base64.encode_exn (Crypto.(sha_1 (of_string (nonce ^ websocket_uuid)) |> to_string)) in
  match version, status, upgrade_hdr, sec_ws_accept_hdr with
  | { major = 1 ; minor = 1 },
    `Switching_protocols,
    Some "websocket",
    Some v when v = expected_sec ->
    Ivar.fill_if_empty iv true
  | _ ->
    Logs.err ~src
      (fun m -> m "Invalid response %a" Response.pp_hum response) ;
    Ivar.fill_if_empty iv false

let error_handler signal e =
  begin match e with
    | `Exn e ->
      Logs.err ~src
        (fun m -> m "Exception %a" Exn.pp e) ;
    | `Invalid_response_body_length resp ->
      Logs.err ~src
        (fun m -> m "Invalid response body length %a" Response.pp_hum resp)
    | `Malformed_response msg ->
      Logs.err ~src
        (fun m -> m "Malformed response %s" msg)
  end ;
  Ivar.fill_if_empty signal false

let connect
    ?(stream = Faraday.create 4096)
    ?(crypto = (module Crypto : CRYPTO))
    ?(extra_headers = Headers.empty)
    uri =
  let open Conduit_async in
  let module Crypto = (val crypto : CRYPTO) in
  let initialized = Ivar.create () in
  let client_r, ws_w = Pipe.create () in
  let ws_r, client_w = Pipe.create () in
  let run (V3.Inet_sock socket) r _ =
    let writev = Faraday_async.writev_of_fd (Socket.fd socket) in
    let rec flush () =
      match Faraday.operation stream with
      | `Close -> raise Exit
      | `Yield -> Deferred.unit
      | `Writev iovecs ->
        writev iovecs >>= function
        | `Closed -> raise Exit
        | `Ok n ->
          Faraday.shift stream n ;
          flush () in
    let nonce =
      Base64.encode_exn Crypto.(generate 16 |> to_string) in
    let headers =
      merge_headers extra_headers (Fastws.headers nonce) in
    let req = Request.create ~headers `GET (Uri.to_string uri) in
    let ok = Ivar.create () in
    let error_handler = error_handler ok in
    let response_handler =
      response_handler ok nonce (module Crypto) in
    let _body, conn =
      Client_connection.request req ~error_handler ~response_handler in
    let rec flush_req () =
      match Client_connection.next_write_operation conn with
      | `Write iovecs ->
        writev iovecs >>> fun result ->
        Client_connection.report_write_result conn result ;
        flush_req ()
      | `Yield ->
        Client_connection.yield_writer conn flush_req ;
      | `Close _ -> () in
    let rec read_response () =
      match Client_connection.next_read_operation conn with
      | `Close -> Deferred.unit
      | `Read -> begin
          Reader.read_one_chunk_at_a_time r
            ~handle_chunk:begin fun buf ~pos ~len ->
              let nb_read = Client_connection.read conn buf ~off:pos ~len in
              return (`Stop_consumed ((), nb_read))
            end >>= function
          | `Eof
          | `Eof_with_unconsumed_data _ ->
            raise Exit
          | `Stopped () ->
            read_response ()
        end in
    flush_req () ;
    don't_wait_for (read_response ()) ;
    Logs_async.debug ~src
      (fun m -> m "%a" Request.pp_hum req) >>= fun () ->
    Ivar.read ok >>= function
    | false -> failwith "Invalid handshake"
    | true ->
      Ivar.fill initialized () ;
      Logs_async.debug ~src
        (fun m -> m "Connected to %a" Uri.pp_hum uri) >>= fun () ->
      don't_wait_for begin
        Pipe.iter ws_r ~f:begin fun t ->
          let mask = Crypto.(to_string (generate 4)) in
          serialize ~mask stream t ;
          flush () >>= fun () ->
          Logs_async.debug ~src (fun m -> m "-> %a" pp t)
        end
      end ;
      (* let rec loop () =
       *   Logs.debug ~src (fun m -> m "BEFORE PARSE") ;
       *   Angstrom_async.parse parser r >>= function
       *   | Error msg ->
       *     Logs_async.err ~src (fun m -> m "%s" msg) >>= fun () ->
       *     failwith msg
       *   | Ok t ->
       *     Logs_async.debug ~src (fun m -> m "<- %a" pp t) >>= fun () ->
       *     Pipe.write ws_w t >>= fun () ->
       *     loop () in
       * don't_wait_for (Deferred.ignore (loop ())) ;
       * Deferred.unit *)
      Angstrom_async.parse_many parser_exn begin fun t ->
        Logs_async.debug ~src (fun m -> m "<- %a" pp t) >>= fun () ->
        Pipe.write ws_w t
      end r >>= function
      | Error msg ->
        Logs_async.err ~src (fun m -> m "%s" msg) >>= fun () ->
        failwith msg
      | Ok () ->
        Logs_async.err ~src (fun m -> m "Connection terminated") >>= fun () ->
        Deferred.unit
  in
  don't_wait_for begin
    Monitor.protect ~here:[%here]
      (fun () -> V3.with_connection_uri uri run)
      ~finally:(fun () -> Pipe.close client_w ; Deferred.unit)
  end ;
  Ivar.read initialized >>| fun () ->
  client_r, client_w

let with_connection ?stream ?crypto ?extra_headers uri ~f =
  connect ?stream ?extra_headers ?crypto uri >>= fun (r, w) ->
  protect
    ~f:(fun () -> f r w)
    ~finally:(fun () -> Pipe.close w ; Pipe.close_read r)

exception Timeout of Int63.t

let connect_ez
    ?(crypto=(module Crypto : CRYPTO))
    ?(binary=false)
    ?extra_headers
    ?hb_ns
    uri =
  let ws_read, client_write = Pipe.create () in
  let cleaned_up = Ivar.create () in
  let last_pong = ref (Time_stamp_counter.now ()) in
  let cleanup ?rw () =
    begin match rw with
      | None -> ()
      | Some (r, w) ->
        Pipe.close_read r ;
        Pipe.close w
    end ;
    Pipe.close_read ws_read ;
    Ivar.fill_if_empty cleaned_up () in
  Clock_ns.every
    ~stop:(Ivar.read cleaned_up)
    (Time_ns.Span.of_int_sec 60)
    Time_stamp_counter.Calibrator.calibrate ;
  let client_read_iv = Ivar.create () in
  don't_wait_for begin
    Monitor.protect ~here:[%here]
      ~finally:(fun () -> cleanup () ; Deferred.unit)
      begin fun () ->
        with_connection ?extra_headers ~crypto uri ~f:begin fun r w ->
          let m = Monitor.current () in
          begin match hb_ns with
            | None -> ()
            | Some span ->
              let send_ping () =
                let now = Time_stamp_counter.now () in
                Pipe.write w ping >>= fun () ->
                let elapsed = Time_stamp_counter.diff now !last_pong in
                let elapsed = Time_stamp_counter.Span.to_ns elapsed in
                if Int63.(elapsed < span + span) then Deferred.unit
                else begin
                  Logs_async.warn ~src begin fun m ->
                    m "No pong received to ping request after %a ns, closing"
                      Int63.pp elapsed
                  end >>| fun () ->
                  Monitor.send_exn m (Timeout elapsed)
                end
              in
              Clock_ns.run_at_intervals'
                ~continue_on_error:false
                ~stop:(Ivar.read cleaned_up)
                (Time_ns.Span.of_int63_ns span)
                send_ping
          end ;
          let filter =
            let buf = Buffer.create 13 in
            let cont = ref false in
            fun fr ->
              match fr.opcode with
              | Opcode.Ping ->
                Pipe.write w pong >>| fun () ->
                None
              | Close ->
                Pipe.write w fr >>| fun () ->
                Pipe.close w ;
                None
              | Pong ->
                last_pong := Time_stamp_counter.now (); return None
              | Continuation when fr.final ->
                cont := false ;
                Buffer.add_string buf fr.content ;
                return (Some (Buffer.contents buf))
              | Continuation ->
                Buffer.add_string buf fr.content ;
                return None
              | Text
              | Binary when fr.final ->
                return (Some fr.content)
              | Text
              | Binary when not !cont ->
                cont := true ;
                Buffer.clear buf ;
                Buffer.add_string buf fr.content ;
                return None
              | Text
              | Binary ->
                let close_msg =
                  close ~msg:begin
                    Status.ProtocolError,
                    "Fragmented message ongoing"
                  end () in
                Pipe.write w close_msg >>| fun () ->
                Pipe.close w ;
                None
              | _ ->
                let close_msg =
                  close ~msg:(Status.UnsupportedExtension, "") () in
                Pipe.write w close_msg >>| fun () ->
                Pipe.close w ;
                None
          in
          let client_read = Pipe.filter_map' r ~f:filter in
          Ivar.fill client_read_iv client_read ;
          let react () =
            let opcode = if binary then Opcode.Binary else Text in
            Pipe.transfer ws_read w ~f:(fun content -> create ~content opcode) in
          Deferred.any_unit [
            react () ;
            Deferred.all_unit Pipe.[ closed client_read ; closed client_write ]
          ]
        end
      end
  end ;
  Ivar.read client_read_iv >>| fun client_read ->
  client_read, client_write

let with_connection_ez
    ?(crypto=(module Crypto : CRYPTO))
    ?binary ?extra_headers ?hb_ns uri ~f =
  connect_ez ?binary ?extra_headers ?hb_ns ~crypto uri >>= fun (r, w) ->
  Monitor.protect ~here:[%here]
    ~finally:(fun () -> Pipe.close_read r ; Pipe.close w ; Deferred.unit)
    (fun () -> f r w)
