(lang dune 3.0)

(name a2a-client)

(generate_opam_files true)

(source
 (github TaisonTsukada/a2a-ocaml))

(license MIT)

(authors "Taison Tsukada")

(maintainers "Taison Tsukada <ttt.code.dev@gmail.com>")

(documentation "https://github.com/TaisonTsukada/a2a-ocaml#readme")

(package
 (name a2a-client)
 (synopsis "A2A (Agent2Agent) protocol client for OCaml 5 / Eio (v1.0, v0.3 compatible)")
 (description
  "Type-safe client for the A2A (Agent2Agent) protocol v1.0 over the JSON-RPC and HTTP+JSON (REST) bindings, backward compatible with v0.3 agents, using cohttp-eio. Supports Agent Card discovery with protocol version and binding negotiation, every A2A operation (messages, tasks, ListTasks, push notification configs, extended Agent Card), incremental Server-Sent Events streaming with optional resumption, keep-alive connection pooling, and task lifecycle helpers with bounded polling.")
 (tags (a2a agent2agent agents ai json-rpc rest sse eio))
 (depends
  (ocaml (>= 5.1))
  (eio (>= 1.0))
  (cstruct (>= 6.0))
  (cohttp-eio (>= 6.2.1))
  (cohttp (>= 6.2.1))
  (http (>= 6.2.1))
  (uri (>= 4.0))
  (yojson (>= 3.0))
  (base64 (>= 3.0))
  (ptime (>= 1.0))
  (uuidm (>= 0.9.9))
  (logs (>= 0.7))
  (mtime (>= 2.0))
  (alcotest :with-test)
  (eio_main :with-test)
  (odoc :with-doc)))
