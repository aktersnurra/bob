(lang dune 3.24)
(name bob)
(generate_opam_files true)

(package
 (name bob)
 (synopsis "Bob — a small curious desktop robot")
 (allow_empty)
 (depends
  (ocaml (>= 5.2))
  dune
  mtime
  ptime
  yojson
  uuidm
  sqlite3
  cmdliner
  logs
  fmt
  (alcotest :with-test)
  (qcheck-core :with-test)
  (qcheck-alcotest :with-test)))
