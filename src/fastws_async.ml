(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Httpaf

open Core
open Async

open Fastws

let src = Logs.Src.create "fastws.async"
module Log = (val Logs.src_log src : Logs.LOG)
module Log_async = (val Logs_async.src_log src : Logs_async.LOG)

type t =
  | Header of Fastws.t
  | Payload of Bigstring.t [@@deriving sexp]

let header = function Header _ -> true | _ -> false

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
  Log.debug (fun m -> m "%a" Response.pp_hum response) ;
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
    Log.err (fun m -> m "Invalid response %a" Response.pp_hum response) ;
    Ivar.fill_if_empty iv false

let error_handler signal e =
  begin match e with
    | `Exn e ->
      Log.err (fun m -> m "Exception %a" Exn.pp e) ;
    | `Invalid_response_body_length resp ->
      Log.err (fun m -> m "Invalid response body length %a" Response.pp_hum resp)
    | `Malformed_response msg ->
      Log.err (fun m -> m "Malformed response %s" msg)
  end ;
  Ivar.fill_if_empty signal false

let write_iovec w iovec =
  List.fold_left iovec ~init:0 ~f:begin fun a { Faraday.buffer ; off ; len } ->
    Writer.write_bigstring w buffer ~pos:off ~len ;
    a+len
  end

let rec flush_req conn w =
  match Client_connection.next_write_operation conn with
  | `Write iovec ->
    let nb_read = write_iovec w iovec in
    Client_connection.report_write_result conn (`Ok nb_read) ;
    flush_req conn w
  | `Yield ->
    Client_connection.yield_writer conn (fun () -> flush_req conn w) ;
  | `Close _ -> ()

let rec read_response conn r =
  match Client_connection.next_read_operation conn with
  | `Close -> Deferred.unit
  | `Read -> begin
      Reader.read_one_chunk_at_a_time r
        ~handle_chunk:begin fun buf ~pos ~len ->
          let nb_read = Client_connection.read conn buf ~off:pos ~len in
          return (`Stop_consumed ((), nb_read))
        end >>= function
      | `Eof
      | `Eof_with_unconsumed_data _ -> raise Exit
      | `Stopped () -> read_response conn r
    end

let rec flush stream w =
  match Faraday.operation stream with
  | `Close -> raise Exit
  | `Yield -> Deferred.unit
  | `Writev iovec ->
    let nb_read = write_iovec w iovec in
    Faraday.shift stream nb_read ;
    flush stream w

let run stream extra_headers initialized ws_r client_w handle url _sock _conn r w =
  let nonce = Base64.encode_exn Crypto.(generate 16 |> to_string) in
  let headers =
    Option.value_map ~default:extra_headers (Uri.host url)
      ~f:(Headers.add extra_headers "Host") in
  let headers = merge_headers headers (Fastws.headers nonce) in
  let req = Request.create ~headers `GET (Uri.path_and_query url) in
  let ok = Ivar.create () in
  let error_handler = error_handler ok in
  let response_handler = response_handler ok nonce (module Crypto) in
  let _body, conn =
    Client_connection.request req ~error_handler ~response_handler in
  flush_req conn w ;
  don't_wait_for (read_response conn r) ;
  Log_async.debug (fun m -> m "%a" Request.pp_hum req) >>= fun () ->
  Deferred.any [ Ivar.read ok ;
                 Clock_ns.after (Time_ns.Span.of_int_sec 10) >>| fun () ->
                 false ] >>= function
  | false ->
    if Ivar.is_full ok then failwith "Invalid handshake"
    else failwith "endpoint does not respond"
  | true ->
    Ivar.fill initialized () ;
    Log_async.debug (fun m -> m "Connected to %a" Uri.pp_hum url) >>= fun () ->
    don't_wait_for begin
      Pipe.fold ws_r ~f:begin fun hdr -> function
        | Header t ->
          let mask = Crypto.(to_string (generate 4)) in
          let h = { t with mask = Some mask } in
          serialize stream h ;
          flush stream w >>= fun () ->
          Log_async.debug (fun m -> m "-> %a" pp t) >>| fun () ->
          Some h
        | Payload buf ->
          match hdr with
          | Some { mask = Some mask ; _ } ->
            xormask ~mask buf ;
            Faraday.write_bigstring stream buf ;
            xormask ~mask buf ;
            flush stream w >>| fun () ->
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
      let read_max already_read =
        let will_read = min (len - already_read) !len_to_read in
        len_to_read := !len_to_read - will_read ;
        let payload = Bigstring.sub_shared buf
            ~pos:(pos+already_read) ~len:will_read in
        handle client_w (Payload payload) >>= fun () ->
        return (`Consumed (already_read + will_read, need !len_to_read)) in
      if !len_to_read > 0 then read_max 0 else
        match parse buf ~pos ~len with
        | `More n -> return (`Consumed (0, `Need (len + n)))
        | `Ok (t, read) ->
          Log_async.debug (fun m -> m "<- %a" pp t) >>= fun () ->
          handle client_w (Header t) >>= fun () ->
          len_to_read := t.length ;
          if read < len then
            read_max read
          else
            return (`Consumed (len, `Need_unknown))
    in
    Reader.read_one_chunk_at_a_time r ~handle_chunk >>= function
    | `Eof
    | `Eof_with_unconsumed_data _ -> Deferred.unit
    | `Stopped _ -> Log_async.err (fun m -> m "Connection terminated")

let connect
    ?(stream = Faraday.create 4096)
    ?(crypto = (module Crypto : CRYPTO))
    ?(extra_headers = Headers.empty)
    ~handle url =
  let module Crypto = (val crypto : CRYPTO) in
  let initialized = Ivar.create () in
  let ws_r, client_w = Pipe.create () in
  let conn =
    Monitor.protect ~here:[%here] begin fun () ->
      Async_uri.with_connection url
        (run stream extra_headers initialized ws_r client_w handle url)
    end ~finally:(fun () -> Pipe.close client_w ; Deferred.unit) in
  Deferred.any_unit [ conn ;  Ivar.read initialized ] >>= fun () ->
  match Ivar.is_full initialized with
  | true -> return client_w
  | false -> failwith "tcp connect timeout"

let with_connection ?stream ?crypto ?extra_headers ~handle ~f uri =
  connect ?stream ?extra_headers ?crypto ~handle uri >>= fun w ->
  Monitor.protect (fun () -> f w)
    ~finally:(fun () -> Pipe.close w ; Pipe.closed w)

type st = {
  buf : Bigbuffer.t ;
  mutable header : Fastws.t option ;
  mutable to_read : int ;
}

let create_st () = {
  buf = Bigbuffer.create 13 ;
  header = None ;
  to_read = 0 ;
}

let reassemble k st t =
  if header t then Bigbuffer.clear st.buf ;
  match t, st.header with
  | Header { opcode; final; _ }, Some { final = false ; _ } when
      final && opcode <> Continuation ->
    k st (`Fail "unfinished continuation")
  | Header { opcode = Continuation ; length ; _ }, _ ->
    st.to_read <- length ;
    k st `Continue
  | Header ({ length = 0 ; final = true ; _ } as h), _ ->
    st.header <- None ;
    k st (`Frame { header = h ; payload = None })
  | Header h, _ ->
    st.header <- Some h ;
    st.to_read <- h.length ;
    k st `Continue
  | Payload _, None ->
    Log.err (fun m -> m "Got %a" Sexplib.Sexp.pp (sexp_of_t t)) ;
    k st (`Fail "payload without a header")
  | Payload b, Some h ->
    let buflen = Bigstring.length b in
    match h.final && buflen = st.to_read with
    | true ->
      Bigbuffer.add_bigstring st.buf b ;
      st.header <- None ;
      let payload = Bigbuffer.volatile_contents st.buf in
      let payload = Bigstring.sub_shared ~len:h.length payload in
      k st (`Frame { header = h ; payload = Some payload })
    | false ->
      Bigbuffer.add_bigstring st.buf b ;
      st.to_read <- st.to_read - buflen ;
      k st `Continue

let pongs_expected = ref String.Set.empty

let process
    cleaning_up cleaned_up last_pong client_w ws_w ({ header ; payload } as frame) =
  match header.opcode with
  | Ping ->
    write_frame ws_w { header = { header with opcode = Pong } ; payload }
  | Close ->
    (if Ivar.is_empty cleaning_up
     then write_frame ws_w frame else Deferred.unit) >>| fun () ->
    Ivar.fill_if_empty cleaned_up ()
  | Pong ->
    last_pong := Time_stamp_counter.now () ;
    begin match frame with
      | { payload = None ; _ } -> Deferred.unit
      | { payload = Some payload ; _ } ->
        assert (Bigstring.length payload = header.length) ;
        let payload_string = Bigstring.to_string payload in
        if String.Set.mem !pongs_expected payload_string then begin
          pongs_expected := String.Set.remove !pongs_expected payload_string ;
          Deferred.unit
        end
        else
          Logs_async.err (fun m -> m "Received wrong data in pong") >>| fun () ->
          Pipe.close ws_w ;
          Pipe.close client_w
    end
  | Text
  | Binary -> begin match frame with
      | { payload = None ; _ } -> Deferred.unit
      | { payload = Some payload ; _ } ->
        assert (Bigstring.length payload = header.length) ;
        let payload = Bigstring.to_string payload in
        Log_async.debug (fun m -> m "<- %s" payload) >>= fun () ->
        Pipe.write_if_open client_w payload
    end
  | Continuation -> assert false
  | _ ->
    write_frame ws_w (close ~status:Status.UnsupportedExtension "") >>| fun () ->
    Pipe.close ws_w ;
    Pipe.close client_w

let heartbeat calibrator w terminate last_pong cleanup cleaned_up span =
  let send_ping () =
    let now = Time_stamp_counter.now () in
    Pipe.write_if_open w (Header (create ~length:8 Ping)) >>= fun () ->
    let buf = Bigstring.create 8 in
    Bigstring.set_int64_le buf ~pos:0 (Random.bits ()) ;
    pongs_expected :=
      String.Set.add !pongs_expected (Bigstring.to_string buf) ;
    Pipe.write_if_open w (Payload buf) >>= fun () ->
    let elapsed = Time_stamp_counter.diff now !last_pong in
    let elapsed =
      Time_stamp_counter.Span.to_ns ~calibrator elapsed in
    if Int63.(elapsed < span + span) then Deferred.unit
    else begin
      Log_async.err begin fun m ->
        m "No pong received to ping request after %a ns, closing"
          Int63.pp elapsed
      end >>| fun () ->
      cleanup () ;
      Ivar.fill terminate ()
    end
  in
  Clock_ns.run_at_intervals'
    ~continue_on_error:false
    ~stop:(Ivar.read cleaned_up)
    (Time_ns.Span.of_int63_ns span)
    send_ping

let assemble_frames binary ws_read w =
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
  let initialized = Ivar.create () in
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
  let m = Monitor.current () in
  don't_wait_for begin
    Monitor.try_with ~here:[%here] begin fun () ->
      with_connection ?extra_headers ~crypto uri ~handle ~f:begin fun w ->
        let hb_terminate = Ivar.create () in
        Option.iter hb_ns ~f:begin fun (c, v) ->
          heartbeat c w hb_terminate last_pong cleanup cleaned_up v
        end ;
        Ivar.fill initialized () ;
        don't_wait_for (assemble_frames binary ws_read w) ;
        Deferred.any_unit [
          Ivar.read hb_terminate ;
          Deferred.all_unit Pipe.[ closed client_read ; closed client_write ] ] >>= fun () ->
        begin
          if Pipe.is_closed w then Deferred.unit
          else write_frame w (close "")
        end >>| fun () ->
        Ivar.fill_if_empty cleaning_up ()
      end
    end >>= function
    | Error exn ->
      Log_async.err (fun m -> m "%a" Exn.pp exn) >>= fun () ->
      cleanup () ;
      Ivar.fill_if_empty cleaned_up () ;
      Monitor.send_exn m exn ;
      Deferred.unit
    | Ok () ->
      cleanup () ;
      Ivar.fill_if_empty cleaned_up () ;
      Deferred.unit
  end ;
  Ivar.read initialized >>| fun () ->
  client_read, client_write, Ivar.read cleaned_up

let with_connection_ez
    ?(crypto=(module Crypto : CRYPTO))
    ?binary ?extra_headers ?hb_ns uri ~f =
  connect_ez
    ?binary ?extra_headers ?hb_ns ~crypto uri >>= fun (r, w, cleaned_up) ->
  Monitor.protect ~here:[%here]
    ~finally:(fun () -> Pipe.close_read r ; Pipe.close w ; cleaned_up)
    (fun () -> f r w)
