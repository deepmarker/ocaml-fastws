(lang dune 3.10)

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
   dune
  (sexplib (>= v0.16))
  (ppx_sexp_conv (>= v0.16))
  (faraday (>= 0.8.2))
  (httpaf (>= 0.7.1))
  (alcotest (and :with-test (>= 1.7.0)))
 )
 (tags
  (websocket async)))

(package
 (name fastws-async)
 (synopsis "Fast websocket library - Async code")
 (depends
   ocaml
   dune
  (camlzip (>= 1.11))
  (digestif (>= 1.1.4))
  (uri-sexp (>= 4.4.0))
  (core (>= v0.16))
  (async (>= v0.16))
   logs-async
  (faraday-async (>= 0.8.2))
  (fastws (= :version))
  (alcotest (and :with-test (>= 1.7.0)))
  (alcotest-async (and :with-test (>= 1.7.0)))
 )
 (tags
  (websocket async)))

(package
 (name fastws-async-bin)
 (synopsis "Fastws utilities")
 (depends
   ocaml
   dune
  (core_unix (>= 0.16))
   logs-async-reporter
  (fastws-async (= :version))
 )
 (tags
  (websocket async)))

; See the complete stanza docs at https://dune.readthedocs.io/en/stable/dune-files.html#dune-project
