(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpaf

open Fastws

type t =
  | Header of Fastws.t
  | Payload of Bigstringaf.t

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
    ~handle uri =
  let open Conduit_async in
  let module Crypto = (val crypto : CRYPTO) in
  let initialized = Ivar.create () in
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
        Pipe.fold ws_r ~f:begin fun hdr -> function
          | Header t ->
            let mask = Crypto.(to_string (generate 4)) in
            let h = { t with mask = Some mask } in
            serialize stream h ;
            flush () >>= fun () ->
            Logs_async.debug ~src (fun m -> m "-> %a" pp t) >>| fun () ->
            Some h
          | Payload buf ->
            match hdr with
            | Some { mask = Some mask ; _ } ->
              xormask ~mask buf ;
              Faraday.write_bigstring stream buf ;
              flush () >>| fun () ->
              hdr
            | _ ->
              failwith "current header must exist"
        end ~init:None >>= fun _ ->
        Deferred.unit
      end ;
      let len_to_read = ref 0 in
      let handle_chunk buf ~pos ~len =
        if !len_to_read > 0 then begin
          let will_read = min len !len_to_read in
          len_to_read := !len_to_read - will_read ;
          handle (Payload (Bigstringaf.sub buf ~off:pos ~len)) >>= fun () ->
          return (`Consumed (will_read, `Need !len_to_read))
        end
        else
          match parse buf ~pos ~len with
          | `More n ->
            return (`Consumed (0, `Need (len + n)))
          | `Ok (t, read) ->
            Logs_async.debug ~src (fun m -> m "<- %a" pp t) >>= fun () ->
            handle (Header t) >>= fun () ->
            len_to_read := t.length ;
            return (`Consumed (read, `Need t.length))
      in
      Reader.read_one_chunk_at_a_time r ~handle_chunk >>= function
      | `Stopped _ ->
        Logs_async.err ~src (fun m -> m "Connection terminated") >>= fun () ->
        Deferred.unit
      | `Eof
      | `Eof_with_unconsumed_data _ ->
        raise End_of_file
  in
  don't_wait_for begin
    Monitor.protect ~here:[%here]
      (fun () -> V3.with_connection_uri uri run)
      ~finally:(fun () -> Pipe.close client_w ; Deferred.unit)
  end ;
  Ivar.read initialized >>| fun () ->
  client_w

let with_connection ?stream ?crypto ?extra_headers uri ~handle ~f =
  connect ?stream ?extra_headers ?crypto ~handle uri >>= fun w ->
  protect ~f:(fun () -> f w) ~finally:(fun () -> Pipe.close w)

exception Timeout of Int63.t

type st = {
  buf : Bigbuffer.t ;
  mutable header : Fastws.t option ;
}

let st () = {
  buf = Bigbuffer.create 13 ;
  header = None ;
}

let reassemble k st t =
  match t, st.header with
  | Header { opcode; final; _ }, Some { final = false ; _ } when
      final && opcode <> Continuation ->
    k st (`Fail "unfinished continuation")
  | Header { opcode = Continuation ; length ; final ; _ }, Some h ->
    st.header <- Some { h with length ; final } ;
    k st `Continue
  | Header h, _ ->
    st.header <- Some h ;
    k st `Continue
  | Payload _, None -> k st (`Fail "payload without a header")
  | Payload b, Some h ->
    begin match Bigstring.length b, h.final with
      | len, false ->
        Bigbuffer.add_bigstring st.buf b ;
        begin match st.header with
        | None -> assert false
        | Some h ->
          st.header <- Some { h with length = h.length - len }
        end ;
        k st `Continue
      | _, true ->
        Bigbuffer.add_bigstring st.buf b ;
        st.header <- None ;
        Bigbuffer.clear st.buf ;
        k st (`Frame (h.opcode, (Bigbuffer.contents st.buf)))
    end

let process last_pong client_w ws_w (({ opcode ; _ } as fr), data) =
  let write_ws hdr data =
    let datalen = match data with
      | None -> 0
      | Some buf -> Bigstringaf.length buf in
    Pipe.write ws_w
      (Header { hdr with length = datalen }) >>= fun () ->
    begin match data with
      | None -> Deferred.unit
      | Some data -> Pipe.write ws_w (Payload data)
    end in
  let write_client = function
    | None -> Deferred.unit
    | Some data -> Pipe.write client_w (Bigstring.to_string data) in
  match opcode with
  | Ping -> write_ws pong data
  | Close -> write_ws fr data
  | Pong ->
    last_pong := Time_stamp_counter.now () ;
    Deferred.unit
  (* | { opcode = Text ; _ }
   * | { opcode = Binary ; _ } when h.final && !cont <> `No ->
   *   let fr =
   *     close ~msg:begin
   *       Status.ProtocolError,
   *       "Fragmented message ongoing"
   *     end () in
   *   Pipe.write ws_w fr >>| fun () ->
   *   Pipe.close ws_w ;
   *   Pipe.close client_w *)
  | Text
  | Binary -> write_client data
  | Continuation -> assert false
  | _ ->
    let hdr, _ = close ~msg:(Status.UnsupportedExtension, "") () in
    write_ws hdr None >>| fun () ->
    Pipe.close ws_w ;
    Pipe.close client_w

let connect_ez
    ?(crypto=(module Crypto : CRYPTO))
    ?(binary=false)
    ?extra_headers
    ?hb_ns
    uri =
  let ws_read, client_write = Pipe.create () in
  let client_read, ws_write = Pipe.create () in
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
        with_connection ?extra_headers ~crypto uri ~handle ~f:begin fun w ->
          let m = Monitor.current () in
          begin match hb_ns with
            | None -> ()
            | Some span ->
              let send_ping () =
                let now = Time_stamp_counter.now () in
                Pipe.write w (Header ping) >>= fun () ->
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
          Ivar.fill client_read_iv client_read ;
          let assemble_frames () =
            let opcode = if binary then Opcode.Binary else Text in
            Pipe.transfer' ws_read w ~f:begin fun mq ->
              let wq = Queue.create () in
              Queue.iter mq ~f:begin fun m ->
                  Queue.enqueue wq (Header (create opcode)) ;
                  Queue.enqueue wq (Payload (Bigstring.of_string m)) ;
              end ;
              return wq
            end
          in
          Deferred.any_unit [
            assemble_frames () ;
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
