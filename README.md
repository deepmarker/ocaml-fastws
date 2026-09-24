# ocaml-fastws [![Build Status](https://api.travis-ci.com/deepmarker/ocaml-fastws.svg?branch=master)](https://travis-ci.com/github/deepmarker/ocaml-fastws)

## Benchmarking permessage-deflate

Run the offline decompression benchmark from the OCaml workspace root:

```sh
dune exec lib/fastws/bin/bench_permessage_deflate.exe -- -iterations 100000
```

The benchmark uses `server_no_context_takeover`, as negotiated by feeds such as
Binance, and reports time and OCaml allocation per message. To compare a
zlib-compatible alternative without relinking fastws, put its compatible
`libz.so.1` directory first in the dynamic loader's library search path when
running the benchmark.
