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

let client
    ?(extra_headers = Headers.empty)
    ?(initialized=Ivar.create ())
    ~crypto uri =
  let open Conduit_async in
  let module Crypto = (val crypto : CRYPTO) in
  let run (V2.Inet_sock socket) _ _ =
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
      Ivar.fill_if_empty initialized () ;
      Deferred.unit
  in
  V2.with_connection_uri uri run

let client_ez
    ?opcode
    ?(name="websocket.client_ez")
    ?extra_headers
    ?heartbeat
    ?random_string
    uri
    net_to_ws ws_to_net =
  let app_to_ws, reactor_write = Pipe.create () in
  let to_reactor_write, client_write = Pipe.create () in
  let client_read, ws_to_app = Pipe.create () in
  let initialized = Ivar.create () in
  let initialized_d = Ivar.read initialized in
  let last_pong = ref @@ Time_ns.epoch in
  let cleanup = lazy begin
    Pipe.close ws_to_app ;
    Pipe.close_read app_to_ws ;
    Pipe.close_read to_reactor_write ;
    Pipe.close client_write
  end in
  let send_ping w span =
    let now = Time_ns.now () in
    Logs_async.debug ~src (fun m -> m "-> PING") >>= fun () ->
    Pipe.write w @@ Frame.create
      ~opcode:Frame.Opcode.Ping
      ~content:(Time_ns.to_string_fix_proto `Utc now) () >>| fun () ->
    let time_since_last_pong = Time_ns.diff now !last_pong in
    if !last_pong > Time_ns.epoch
    && Time_ns.Span.(time_since_last_pong > span + span) then
      Lazy.force cleanup
  in
  let react w fr =
    let open Frame in
    Logs_async.debug ~src (fun m -> m "<- %a" Frame.pp fr) >>= fun () ->
    match fr.opcode with
    | Opcode.Ping ->
        Pipe.write w @@ Frame.create ~opcode:Opcode.Pong () >>| fun () ->
        None
    | Opcode.Close ->
        (* Immediately echo and pass this last message to the user *)
        (if String.length fr.content >= 2 then
           Pipe.write w @@ Frame.create ~opcode:Opcode.Close
             ~content:(String.sub fr.content ~pos:0 ~len:2) ()
         else Pipe.write w @@ Frame.close 1000) >>| fun () ->
        Pipe.close w;
        None
    | Opcode.Pong ->
        last_pong := Time_ns.now (); return None
    | Opcode.Text | Opcode.Binary ->
        return @@ Some fr.content
    | _ ->
        Pipe.write w @@ Frame.close 1002 >>| fun () -> Pipe.close w; None
  in
  let client_read = Pipe.filter_map' client_read ~f:(react reactor_write) in
  let react () =
    initialized_d >>= fun () ->
    Pipe.transfer to_reactor_write reactor_write ~f:(fun content ->
        Frame.create ?opcode ~content ()) in
  (* Run send_ping every heartbeat when heartbeat is set. *)
  don't_wait_for begin match heartbeat with
  | None -> Deferred.unit
  | Some span -> initialized_d >>| fun () ->
    Clock_ns.run_at_intervals'
      ~continue_on_error:false
      ~stop:(Pipe.closed reactor_write)
      span (fun () -> send_ping reactor_write span)
  end ;
  don't_wait_for begin
    Monitor.protect
      ~finally:(fun () -> Lazy.force cleanup ; Deferred.unit)
      begin fun () ->
        Deferred.any_unit [
          (client ~name ?extra_headers ?random_string ~initialized
             ~app_to_ws ~ws_to_app ~net_to_ws ~ws_to_net uri |> Deferred.ignore) ;
          react () ;
          Deferred.all_unit Pipe.[ closed client_read ; closed client_write ; ]
        ]
      end
  end;
  client_read, client_write
