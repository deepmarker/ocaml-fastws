(*---------------------------------------------------------------------------
   Copyright (c) 2019 Vincent Bernardoff. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
  ---------------------------------------------------------------------------*)

open Core
open Async
open Httpaf
open Httpaf_async

open Fastws

module type CRYPTO = sig
  type buffer
  type g
  val generate: ?g:g -> int -> buffer
  val sha1 : buffer -> buffer
  val of_string: string -> buffer
  val to_string: buffer -> string
end

let src =
  Logs.Src.create "fastws.async"

let merge_headers h1 h2 =
  Headers.fold ~init:h2 ~f:begin fun k v a ->
    Headers.add_unless_exists a k v
  end h1

let response_handler iv nonce crypto
    ({ Response.version ; status ; headers ; _ } as response) _body =
  let module Crypto = (val crypto : CRYPTO) in
  Logs.debug ~src
    (fun m -> m "%a" Response.pp_hum response) ;
  let upgrade_hdr = Option.map ~f:String.lowercase (Headers.get headers "upgrade") in
  let sec_ws_accept_hdr = Headers.get headers "sec-websocket-accept" in
  let expected_sec =
    B64.encode (Crypto.(sha1 (of_string (nonce ^ websocket_uuid)) |> to_string)) in
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
    ?(extra_headers = Headers.empty)
    ~crypto uri =
  let open Conduit_async in
  let module Crypto = (val crypto : CRYPTO) in
  let initialized = Ivar.create () in
  let rr, ww = Pipe.create () in
  let run (V2.Inet_sock socket) r _ =
    let stream = Faraday.create 4096 in
    let writev = Faraday_async.writev_of_fd (Socket.fd socket) in
    don't_wait_for begin
      Faraday_async.serialize stream
        ~writev ~yield:(fun _ -> Scheduler.yield ())
    end ;
    let nonce = Crypto.(generate 16 |> to_string) in
    let headers =
      merge_headers extra_headers (Fastws.headers nonce) in
    let req = Request.create ~headers `GET (Uri.to_string uri) in
    let ok = Ivar.create () in
    let err = Ivar.create () in
    let error_handler = error_handler err in
    let response_handler =
      response_handler ok nonce (module Crypto) in
    Logs_async.debug ~src
      (fun m -> m "%a" Request.pp_hum req) >>= fun () ->
    let _body = Client.request
        ~error_handler ~response_handler socket req in
    Deferred.any [Ivar.read ok ; Ivar.read err] >>= function
    | false -> failwith "Invalid handshake"
    | true ->
      Ivar.fill initialized ();
      don't_wait_for @@
      Pipe.iter rr ~f:begin fun t ->
        Logs_async.debug ~src (fun m -> m "-> %a" pp t) >>| fun () ->
        serialize stream t
      end ;
      Angstrom_async.parse_many parser begin fun t ->
        Logs_async.debug ~src (fun m -> m "<- %a" pp t) >>= fun () ->
        Pipe.write ww t
      end r >>= function
      | Error msg -> failwith msg
      | Ok () -> Deferred.unit
  in
  Deferred.any [
    Monitor.protect
      (fun () -> V2.with_connection_uri uri run)
      ~finally:(fun () -> Pipe.close ww ; Deferred.unit) ;
    Ivar.read initialized
  ] >>| fun () ->
  rr, ww

let with_connection ?extra_headers ~crypto uri ~f =
  connect ?extra_headers ~crypto uri >>= fun (r, w) ->
  protect
    ~f:(fun () -> f r w)
    ~finally:(fun () -> Pipe.close w ; Pipe.close_read r)

exception Timeout of Int63.t

let connect_ez
    ?(binary=false)
    ?extra_headers
    ?hb_ns
    ~crypto
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
    Monitor.protect
      ~finally:(fun () -> cleanup () ; Deferred.unit) begin fun () ->
      connect ?extra_headers ~crypto uri >>= fun (r, w) ->
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
                m "No pong received to ping request after %a ns, closing" Int63.pp elapsed
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
  end;
  Ivar.read client_read_iv >>| fun client_read ->
  client_read, client_write
