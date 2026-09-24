(lang dune 3.17)

(name fastws)

(generate_opam_files true)

(source
 (github deepmarker/ocaml-fastws))

(authors "Vincent Bernardoff <vb@luminar.eu.org>")

(maintainers "Vincent Bernardoff <vb@luminar.eu.org>")

(license ISC)

(documentation https://deepmarker.github.io/fastws)

(package
 (name fastws)
 (synopsis "Fast websocket library")
 (depends
  ocaml
  sexplib
  ppx_sexp_conv
  faraday
  httpun-types
  uutf
  (alcotest :with-test))
 (tags
  (websocket async)))

(package
 (name fastws-async)
 (synopsis "Fast websocket library - Async client and server")
 (depends
  ocaml
  (fastws
   (= :version))
  httpun
  digestif
  camlzip
  uri-sexp
  core
  async
  logs-async
  faraday-async
  async-uri
  ppx_jane
  ppx_trace
  (alcotest :with-test)
  (alcotest-async :with-test)
  (logs-async-reporter :with-test)))

(package
 (name fastws-async-bin)
 (synopsis "Fastws utilities")
 (depends
  ocaml
  core_unix
  logs-async-reporter
  (fastws-async
   (= :version))))
