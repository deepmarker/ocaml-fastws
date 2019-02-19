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

type t =
  | Header of Fastws.t
  | Payload of Bigstring.t

let header = function Header _ -> true | _ -> false
(* let payload = function Payload _ -> true | _ -> false *)

let write_frame w { header ; payload } =
  Pipe.write w (Header header) >>= fun () ->
  match payload with
  | None -> Deferred.unit
  | Some payload -> Pipe.write w (Payload payload)

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
              xormask ~mask buf ;
              flush () >>| fun () ->
              hdr
            | _ ->
              failwith "current header must exist"
        end ~init:None >>= fun _ ->
        Deferred.unit
      end ;
      let len_to_read = ref 0 in
      let need = function
        | 0 -> `Need_unknown
        | n -> `Need n in
      let handle_chunk buf ~pos ~len =
        Logs_async.debug
          (fun m -> m "handle_chunk %d %d" pos len) >>= fun () ->
        let read_max already_read =
          let will_read = min len !len_to_read in
          len_to_read := !len_to_read - will_read ;
          let payload = Bigstringaf.sub buf
              ~off:(pos+already_read) ~len:(len-already_read) in
          handle client_w (Payload payload) >>= fun () ->
          Logs_async.debug
            (fun m -> m "consumed %d %d" (already_read + will_read) !len_to_read) >>= fun () ->
          return (`Consumed (already_read + will_read, need !len_to_read)) in
        if !len_to_read > 0 then read_max 0 else
          match parse buf ~pos ~len with
          | `More n -> return (`Consumed (0, `Need (len + n)))
          | `Ok (t, read) ->
            Logs_async.debug ~src (fun m -> m "<- %a" pp t) >>= fun () ->
            handle client_w (Header t) >>= fun () ->
            len_to_read := t.length ;
            if read < len then
              read_max read
            else
              return (`Consumed (len, `Need_unknown))
      in
      Reader.read_one_chunk_at_a_time r ~handle_chunk >>= function
      | `Stopped _ ->
        Logs_async.err ~src (fun m -> m "Connection terminated") >>= fun () ->
        Deferred.unit
      | `Eof
      | `Eof_with_unconsumed_data _ ->
        Deferred.unit
  in
  don't_wait_for begin
    Monitor.protect ~here:[%here]
      (fun () -> V3.with_connection_uri uri run)
      ~finally:(fun () -> Pipe.close client_w ; Deferred.unit)
  end ;
  Ivar.read initialized >>| fun () ->
  client_w

let with_connection ?stream ?crypto ?extra_headers ~handle ~f uri =
  connect ?stream ?extra_headers ?crypto ~handle uri >>= fun w ->
  Monitor.protect (fun () -> f w)
    ~finally:(fun () -> Pipe.close w ; Pipe.closed w)

exception Timeout of Int63.t

type st = {
  buf : Bigbuffer.t ;
  mutable header : Fastws.t option ;
}

let create_st () = {
  buf = Bigbuffer.create 13 ;
  header = None ;
}

let reassemble k st t =
  if header t then Bigbuffer.clear st.buf ;
  match t, st.header with
  | Header { opcode; final; _ }, Some { final = false ; _ } when
      final && opcode <> Continuation ->
    k st (`Fail "unfinished continuation")
  | Header { opcode = Continuation ; length ; final ; _ }, Some h ->
    st.header <- Some { h with length ; final } ;
    k st `Continue
  | Header ({ length = 0 ; final = true ; _ } as h), _ ->
    st.header <- None ;
    k st (`Frame { header = h ; payload = None })
  | Header h, _ ->
    st.header <- Some h ;
    k st `Continue
  | Payload _, None -> k st (`Fail "payload without a header")
  | Payload b, Some h ->
    match h.final, Bigbuffer.length st.buf with
    | false, _ ->
      Bigbuffer.add_bigstring st.buf b ;
      begin match st.header with
        | None -> assert false
        | Some h ->
          st.header <- Some { h with length = h.length - Bigstring.length b }
      end ;
      k st `Continue
    | _, 0 ->
      st.header <- None ;
      k st (`Frame { header = h ; payload = Some b })
    | _ ->
      Bigbuffer.add_bigstring st.buf b ;
      st.header <- None ;
      let payload = Bigbuffer.volatile_contents st.buf in
      let payload = Bigstring.sub_shared ~len:h.length payload in
      k st (`Frame { header  = h ; payload = Some payload })

let process
    cleaning_up cleaned_up last_pong client_w ws_w ({ header ; payload } as frame) =
  let write_client = function
    | { payload = None ; _ } -> Deferred.unit
    | { payload = Some payload ; _ } ->
      Pipe.write client_w (Bigstring.to_string payload) in
  match header.opcode with
  | Ping ->
    write_frame ws_w { header = { header with opcode = Pong } ; payload }
  | Close ->
    begin if Ivar.is_empty cleaning_up then
        write_frame ws_w frame
      else Deferred.unit
    end >>| fun () ->
    Ivar.fill_if_empty cleaned_up ()
  | Pong ->
    last_pong := Time_stamp_counter.now () ;
    Deferred.unit
  | Text
  | Binary -> write_client frame
  | Continuation -> assert false
  | _ ->
    write_frame ws_w (close ~status:Status.UnsupportedExtension "") >>| fun () ->
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
  let cleaning_up = Ivar.create () in
  let cleaned_up = Ivar.create () in
  let last_pong = ref (Time_stamp_counter.now ()) in
  let cleanup () =
    Pipe.close_read ws_read in
  Clock_ns.every
    ~stop:(Ivar.read cleaned_up)
    (Time_ns.Span.of_int_sec 60)
    Time_stamp_counter.Calibrator.calibrate ;
  let client_read_iv = Ivar.create () in
  let handle =
    let state = ref (create_st ()) in
    let inner w t =
      reassemble begin fun st s ->
        state := st ;
        match s with
        | `Fail msg -> failwith msg
        | `Continue -> Deferred.unit
        | `Frame fr -> process cleaning_up cleaned_up last_pong ws_write w fr
      end !state t in
    fun w t -> inner w t in
  don't_wait_for begin
    Monitor.try_with ~here:[%here] begin fun () ->
      with_connection ?extra_headers ~crypto uri ~handle ~f:begin fun w ->
        let m = Monitor.current () in
        begin match hb_ns with
          | None -> ()
          | Some span ->
            let send_ping () =
              let now = Time_stamp_counter.now () in
              Pipe.write w (Header (create Ping)) >>= fun () ->
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
          let wq = Queue.create () in
          Pipe.transfer' ws_read w ~f:begin fun mq ->
            Queue.clear wq ;
            Queue.iter mq ~f:begin fun m ->
              let { header ; payload } = match binary with
                | true -> Fastws.binary m
                | false -> Fastws.text m in
              Queue.enqueue wq (Header header) ;
              match payload with
              | None -> ()
              | Some payload -> Queue.enqueue wq (Payload payload)
            end ;
            return wq
          end
        in
        Deferred.any_unit [
          assemble_frames () ;
          Deferred.all_unit Pipe.[ closed client_read ; closed client_write ]
        ] >>= fun () ->
        write_frame w (close "") >>= fun () ->
        Ivar.fill_if_empty cleaning_up () ;
        Ivar.read cleaned_up
      end
    end >>= function
    | Error exn ->
      Logs_async.err ~src (fun m -> m "%a" Exn.pp exn) >>= fun () ->
      cleanup () ;
      Ivar.fill_if_empty cleaned_up () ;
      Deferred.unit
    | Ok () ->
      cleanup () ;
      Deferred.unit
  end ;
  Ivar.read client_read_iv >>| fun client_read ->
  client_read, client_write, Ivar.read cleaned_up

let with_connection_ez
    ?(crypto=(module Crypto : CRYPTO))
    ?binary ?extra_headers ?hb_ns uri ~f =
  connect_ez
    ?binary ?extra_headers ?hb_ns ~crypto uri >>= fun (r, w, cleaned_up) ->
  Monitor.protect ~here:[%here]
    ~finally:(fun () -> Pipe.close_read r ; Pipe.close w ; cleaned_up)
    (fun () -> f r w)
