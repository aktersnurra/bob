open Bob_types

let at ms = Time.of_ms ms

(* Each test gets an isolated temp dir; nothing touches the real bob-data. *)
let with_store f =
  let dir = Filename.temp_file "bob_test_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let store = Bob_memory.open_store ~dir in
  Fun.protect
    ~finally:(fun () -> Bob_memory.close store)
    (fun () -> f store)

let ep ~id ~participants ~turns =
  Bob_memory.
    { id = Episode_id.v id;
      started_at = at 0.;
      ended_at = at 1000.;
      participants = List.map Person_id.v participants;
      turns;
      summary = None }

let test_episode_roundtrip () =
  with_store (fun s ->
      let e = ep ~id:"e1" ~participants:[ "gustaf" ]
          ~turns:[ (at 0., Some "gustaf", "where is the screwdriver") ] in
      Bob_memory.put_episode s e;
      match Bob_memory.get_episode s (Episode_id.v "e1") with
      | Some got ->
          Alcotest.(check int) "participants" 1 (List.length got.Bob_memory.participants);
          Alcotest.(check int) "turns" 1 (List.length got.Bob_memory.turns)
      | None -> Alcotest.fail "episode not found")

let test_fts_finds_episode_by_content () =
  with_store (fun s ->
      Bob_memory.put_episode s
        (ep ~id:"e1" ~participants:[ "gustaf" ]
           ~turns:[ (at 0., Some "gustaf", "the screwdriver is in the drawer") ]);
      Bob_memory.put_episode s
        (ep ~id:"e2" ~participants:[ "gustaf" ]
           ~turns:[ (at 0., Some "gustaf", "we talked about dinosaurs") ]);
      let hits = Bob_memory.search_episodes s ~person:(Person_id.v "gustaf")
          ~query:"screwdriver" ~limit:10 in
      Alcotest.(check int) "one hit" 1 (List.length hits);
      Alcotest.(check string) "right one" "e1"
        (Episode_id.to_string (List.hd hits).Bob_memory.id))

(* SPEC section 30: memory isolation. *)
let test_search_never_returns_another_persons_episode () =
  with_store (fun s ->
      Bob_memory.put_episode s
        (ep ~id:"g1" ~participants:[ "gustaf" ]
           ~turns:[ (at 0., Some "gustaf", "secret screwdriver location") ]);
      Bob_memory.put_episode s
        (ep ~id:"o1" ~participants:[ "olle" ]
           ~turns:[ (at 0., Some "olle", "olle likes screwdriver too") ]);
      let hits = Bob_memory.search_episodes s ~person:(Person_id.v "olle")
          ~query:"screwdriver" ~limit:10 in
      Alcotest.(check int) "only olle's" 1 (List.length hits);
      Alcotest.(check string) "o1" "o1"
        (Episode_id.to_string (List.hd hits).Bob_memory.id))

let test_shared_episode_is_visible_to_both_participants () =
  with_store (fun s ->
      Bob_memory.put_episode s
        (ep ~id:"shared" ~participants:[ "gustaf"; "olle" ]
           ~turns:[ (at 0., Some "gustaf", "we built a lamp together") ]);
      let g = Bob_memory.search_episodes s ~person:(Person_id.v "gustaf") ~query:"lamp" ~limit:10 in
      let o = Bob_memory.search_episodes s ~person:(Person_id.v "olle") ~query:"lamp" ~limit:10 in
      Alcotest.(check int) "gustaf sees it" 1 (List.length g);
      Alcotest.(check int) "olle sees it" 1 (List.length o))

let test_profile_roundtrip () =
  with_store (fun s ->
      let p = Person_id.v "gustaf" in
      Bob_memory.write_profile s p "# Gustaf\n- Prefers Swedish.\n";
      Alcotest.(check (option string)) "read back"
        (Some "# Gustaf\n- Prefers Swedish.\n") (Bob_memory.read_profile s p))

let test_missing_profile_is_none_not_an_error () =
  with_store (fun s ->
      Alcotest.(check (option string)) "none" None
        (Bob_memory.read_profile s (Person_id.v "nobody")))

let test_profile_write_is_size_budgeted () =
  with_store (fun s ->
      let p = Person_id.v "gustaf" in
      let huge = String.make (Bob_memory.max_profile_bytes + 1) 'x' in
      match Bob_memory.write_profile_checked s p huge with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "expected size rejection")

let test_profile_write_is_atomic () =
  (* A failed write must leave the previous profile intact. *)
  with_store (fun s ->
      let p = Person_id.v "gustaf" in
      Bob_memory.write_profile s p "# Gustaf\n- original\n";
      let huge = String.make (Bob_memory.max_profile_bytes + 1) 'x' in
      ignore (Bob_memory.write_profile_checked s p huge);
      Alcotest.(check (option string)) "unchanged"
        (Some "# Gustaf\n- original\n") (Bob_memory.read_profile s p))

let test_profile_path_rejects_traversal () =
  with_store (fun s ->
      (* A person id must never escape the people directory. *)
      match Bob_memory.write_profile_checked s (Person_id.v "../../etc/passwd") "x" with
      | Error _ -> ()
      | Ok () -> Alcotest.fail "expected rejection of traversal in person id")

let test_store_survives_reopen () =
  let dir = Filename.temp_file "bob_persist_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let s = Bob_memory.open_store ~dir in
  Bob_memory.put_episode s
    (ep ~id:"e1" ~participants:[ "gustaf" ] ~turns:[ (at 0., Some "gustaf", "hej") ]);
  Bob_memory.write_profile s (Person_id.v "gustaf") "# Gustaf\n";
  Bob_memory.close s;
  let s2 = Bob_memory.open_store ~dir in
  Alcotest.(check bool) "episode persisted" true
    (Bob_memory.get_episode s2 (Episode_id.v "e1") <> None);
  Alcotest.(check bool) "profile persisted" true
    (Bob_memory.read_profile s2 (Person_id.v "gustaf") <> None);
  Bob_memory.close s2

let test_search_respects_limit () =
  with_store (fun s ->
      List.iter
        (fun i ->
          Bob_memory.put_episode s
            (ep ~id:(Printf.sprintf "e%d" i) ~participants:[ "gustaf" ]
               ~turns:[ (at 0., Some "gustaf", "screwdriver talk") ]))
        (List.init 10 Fun.id);
      let hits = Bob_memory.search_episodes s ~person:(Person_id.v "gustaf")
          ~query:"screwdriver" ~limit:3 in
      Alcotest.(check int) "limited" 3 (List.length hits))

let () =
  Alcotest.run "memory"
    [ ("episodes",
       [ Alcotest.test_case "roundtrip" `Quick test_episode_roundtrip;
         Alcotest.test_case "fts" `Quick test_fts_finds_episode_by_content;
         Alcotest.test_case "limit" `Quick test_search_respects_limit;
         Alcotest.test_case "persists" `Quick test_store_survives_reopen ]);
      ("isolation",
       [ Alcotest.test_case "no cross-person leak" `Quick
           test_search_never_returns_another_persons_episode;
         Alcotest.test_case "shared visible to both" `Quick
           test_shared_episode_is_visible_to_both_participants ]);
      ("profiles",
       [ Alcotest.test_case "roundtrip" `Quick test_profile_roundtrip;
         Alcotest.test_case "missing is none" `Quick test_missing_profile_is_none_not_an_error;
         Alcotest.test_case "size budget" `Quick test_profile_write_is_size_budgeted;
         Alcotest.test_case "atomic" `Quick test_profile_write_is_atomic;
         Alcotest.test_case "no traversal" `Quick test_profile_path_rejects_traversal ]) ]
