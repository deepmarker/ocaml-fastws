# ocaml-fastws

A WebSocket library for OCaml ([RFC 6455]), client and server, for
[Async]. It carries DeepMarker's market-data feeds: long-lived connections to
crypto exchanges holding tens of thousands of streams each, where a
connection that looks alive but delivers nothing is the failure that matters.

- **Frames and pipes.** A connection is a pair of Async pipes. You supply a
  function from received frames to your message type and one from your
  message type to frames, so text, binary or already-parsed messages flow
  through the same interface. Fragmented messages are reassembled before they
  reach you.
- **Client.** `ws://` and `wss://` (TLS through [async-uri]), a connection
  timeout, subprotocols, extra handshake headers.
- **Server.** `Fastws_async.Server.accept` upgrades a connection you already
  hold. `Server.serve` runs a handler per connection on a TCP listener. The
  server answers malformed and wrong-version upgrades with 400 and 426, and
  never masks its frames.
- **permessage-deflate** ([RFC 7692]) on the client side, including the
  no-context-takeover variants exchanges negotiate, with zlib streams reused
  across messages.
- **Liveness.** `hb` sends periodic pings to keep the socket warm. `max_idle`
  closes the connection when the peer has sent no data for that long. Pongs
  deliberately don't count: the peer's WebSocket library answers them even
  when the feed behind it has stopped. Without this, a dead peer can look
  connected for about fifteen minutes on Linux, until TCP gives up
  retransmitting.
- **Strict protocol checks.** Invalid close frames, reserved bits without a
  negotiated extension, and fragmented control frames fail the connection
  with 1002, as the RFC requires. `bin/wstest` runs the [Autobahn] test
  suite against the client.

## Packages

| Package | Contents |
|---|---|
| `fastws` | Frame types, parser and serializer, handshake helpers. No I/O. |
| `fastws-async` | Async client and server, permessage-deflate, liveness. |
| `fastws-async-bin` | `wscat` (a console client), `wstest` (the Autobahn driver). |

## Client

```ocaml
open Core
open Async

let main () =
  Fastws_async.connect_or_error
    ~timeout:(Time_ns.Span.of_int_sec 10)
    ~hb:(Time_ns.Span.of_int_sec 20)
    Fastws_async.of_frame_s
    Fastws_async.to_frame_s
    (Uri.of_string "wss://ws.okx.com:8443/ws/v5/public")
  >>=? fun { r; w } ->
  Pipe.write_without_pushback w
    {|{"op":"subscribe","args":[{"channel":"tickers","instId":"BTC-USDT"}]}|};
  Pipe.iter_without_pushback r ~f:print_endline |> Deferred.ok
```

`of_frame_s` and `to_frame_s` read payloads as strings and send strings as
text frames. Pass your own functions to work with frames directly.
`with_connection` connects over a reader and writer you already hold, and
closes the connection when your function returns.

## Server

```ocaml
open Async

(* An echo server *)
let main () =
  Fastws_async.Server.serve
    (Tcp.Where_to_listen.of_port 9001)
    Fastws_async.of_frame_s
    Fastws_async.to_frame_s
    (fun _addr request conn ->
       printf "connected: %s\n%!" request.target;
       Pipe.transfer_id conn.r conn.w)
  >>= fun _server -> Deferred.never ()
```

The server doesn't offer permessage-deflate, which the RFC allows: clients
then send uncompressed frames. `bin/wsecho.ml` is this example as a program.

## Building

```sh
dune build @install @runtest
```

## Benchmarking permessage-deflate

```sh
dune exec bin/bench_permessage_deflate.exe -- -iterations 100000
```

The benchmark decompresses representative message sizes offline, using
`server_no_context_takeover` as negotiated by feeds such as Binance. It
reports time and OCaml allocation per message. To compare a zlib-compatible
alternative without relinking, put the directory holding its `libz.so.1`
first in the dynamic loader's search path when running the benchmark.

## License

ISC. See [LICENSE.md](LICENSE.md).

[RFC 6455]: https://www.rfc-editor.org/rfc/rfc6455
[RFC 7692]: https://www.rfc-editor.org/rfc/rfc7692
[Async]: https://github.com/janestreet/async
[async-uri]: https://github.com/vbmithr/async-uri
[Autobahn]: https://github.com/crossbario/autobahn-testsuite
