(* Adversarial audit of memory isolation and the projector boundary.
   NOT from the plan. These protect real children's data in deployment, so
   they probe for leaks rather than confirming the happy path. *)

open Bob_types

let at ms = Time.of_ms ms

let with_store f =
  let dir = Filename.temp_file "bob_audit_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let s = Bob_memory.open_store ~dir in
  Fun.protect ~finally:(fun () -> Bob_memory.close s) (fun () -> f s)

let contains haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let ep ~id ~participants ~body =
  Bob_memory.
    { id = Episode_id.v id;
      started_at = at 0.;
      ended_at = at 1000.;
      participants = List.map Person_id.v participants;
      turns = [ (at 0., Some (List.hd participants), body) ];
      summary = None }

(* 1. FTS query injection must not break out of the participant filter.
   An attacker-ish query string should return nothing extra, not everything. *)
let test_fts_query_cannot_escape_the_participant_filter () =
  with_store (fun s ->
      Bob_memory.put_episode s (ep ~id:"g1" ~participants:[ "gustaf" ] ~body:"gustaf secret");
      Bob_memory.put_episode s (ep ~id:"o1" ~participants:[ "olle" ] ~body:"olle secret");
      (* FTS5 special syntax; must stay scoped to olle regardless *)
      List.iter
        (fun q ->
          let hits =
            try Bob_memory.search_episodes s ~person:(Person_id.v "olle") ~query:q ~limit:50
            with _ -> []
          in
          List.iter
            (fun (e : Bob_memory.episode) ->
              let id = Episode_id.to_string e.Bob_memory.id in
              if id <> "o1" then
                Alcotest.failf "query %S leaked episode %s to olle" q id)
            hits)
        [ "secret"; "secret OR gustaf"; "g*"; "\"secret\""; "NEAR(secret gustaf)" ])

(* 2. A person id that is a SQL-ish or FTS-ish string must not widen the scope. *)
let test_odd_person_id_does_not_widen_scope () =
  with_store (fun s ->
      Bob_memory.put_episode s (ep ~id:"g1" ~participants:[ "gustaf" ] ~body:"gustaf secret");
      List.iter
        (fun pid ->
          let hits =
            try
              Bob_memory.search_episodes s ~person:(Person_id.v pid) ~query:"secret" ~limit:50
            with _ -> []
          in
          Alcotest.(check int)
            (Printf.sprintf "person %S sees nothing" pid)
            0 (List.length hits))
        [ "' OR 1=1 --"; "%"; "*"; ""; "gustaf2"; "GUSTAF" ])

(* 3. Deleting a person must remove their profile from disk, not just the db. *)
let test_delete_person_removes_profile_from_disk () =
  with_store (fun s ->
      let p = Person_id.v "olle" in
      Bob_memory.write_profile s p "# Olle\n- likes dinosaurs\n";
      Alcotest.(check bool) "written" true (Bob_memory.read_profile s p <> None);
      (match Bob_memory.delete_person s p with
      | Ok () -> ()
      | Error m -> Alcotest.failf "delete failed: %s" m);
      Alcotest.(check bool) "gone" true (Bob_memory.read_profile s p = None))

(* 4. Profile traversal: several shapes that must all be refused. *)
let test_traversal_shapes_all_refused () =
  with_store (fun s ->
      List.iter
        (fun pid ->
          match Bob_memory.write_profile_checked s (Person_id.v pid) "pwned" with
          | Error _ -> ()
          | Ok () -> Alcotest.failf "accepted dangerous person id %S" pid)
        [ "../escape"; "a/b"; "."; ".."; "" ])

(* 5. An atomic write must never leave the temp file behind as a visible profile. *)
let test_no_temp_file_left_after_write () =
  with_store (fun s ->
      let p = Person_id.v "gustaf" in
      Bob_memory.write_profile s p "# Gustaf\n";
      let dir = Filename.concat (Filename.concat s.Bob_memory.dir "people") "gustaf" in
      let entries = Sys.readdir dir |> Array.to_list in
      Alcotest.(check bool) "no tmp left" false
        (List.exists (fun e -> contains e "tmp") entries))

(* 6. THE projector invariant: a profile belonging to one person, rendered for a
   scene containing another, must not leak. Drive it through the real call. *)
let test_projector_renders_only_the_given_profile () =
  with_store (fun s ->
      Bob_memory.write_profile s (Person_id.v "gustaf") "# Gustaf\n- runs a secret lab\n";
      Bob_memory.write_profile s (Person_id.v "olle") "# Olle\n- likes dinosaurs\n";
      let ttl = Bob_world.default_ttl in
      let world =
        List.fold_left Bob_world.apply (Bob_world.empty ~ttl)
          [ Bob_events.Person_entered
              { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 0. };
            Bob_events.Person_identified
              { at = at 10.; track = Track_id.v 7; person = Person_id.v "gustaf";
                confidence = Confidence.v 0.95 } ]
      in
      (* Gustaf is the one VISIBLE, but we are rendering for Olle's session. *)
      let ctx =
        Bob_project.render ~now:(at 20.) ~world
          ~workspace:(Bob_workspace.empty ~config:Bob_workspace.default_config)
          ~profile:(Bob_memory.read_profile s (Person_id.v "olle"))
          ~episodes:[]
      in
      Alcotest.(check bool) "olle's fact present" true (contains ctx "dinosaurs");
      Alcotest.(check bool) "gustaf's fact absent" false (contains ctx "secret lab"))

(* 7. The projector must stay bounded even when every input is oversized. *)
let test_projector_bounded_under_all_large_inputs () =
  let ttl = Bob_world.default_ttl in
  let world =
    List.init 30 (fun i ->
        Bob_events.Person_entered
          { at = at 0.; track = Track_id.v i; bearing = Angle.deg (float_of_int i) })
    |> List.fold_left Bob_world.apply (Bob_world.empty ~ttl)
  in
  let ws =
    List.init 100 (fun i ->
        Bob_events.Utterance
          { at = at (float_of_int i);
            text = String.make 200 'z';
            speaker = Some (Person_id.v "gustaf");
            speaker_track = None;
            language = Some "en" })
    |> List.fold_left Bob_workspace.apply
         (Bob_workspace.empty ~config:Bob_workspace.default_config)
  in
  let profile = String.concat "\n" (List.init 2000 (fun i -> Printf.sprintf "- f%d" i)) in
  let ctx = Bob_project.render ~now:(at 200.) ~world ~workspace:ws ~profile:(Some profile) ~episodes:[] in
  Alcotest.(check bool)
    (Printf.sprintf "bounded (got %d, max %d)" (String.length ctx) Bob_project.max_chars)
    true
    (String.length ctx <= Bob_project.max_chars)

(* 8. Even under that load, no internal representation may appear. *)
let test_no_internals_leak_under_load () =
  let ttl = Bob_world.default_ttl in
  let world =
    List.init 12 (fun i ->
        Bob_events.Person_entered
          { at = at 0.; track = Track_id.v i; bearing = Angle.deg (float_of_int (i * 7)) })
    |> List.fold_left Bob_world.apply (Bob_world.empty ~ttl)
  in
  let ctx =
    Bob_project.render ~now:(at 10.) ~world
      ~workspace:(Bob_workspace.empty ~config:Bob_workspace.default_config)
      ~profile:None ~episodes:[]
  in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool)
        (Printf.sprintf "no %S" forbidden)
        false (contains ctx forbidden))
    [ "track_"; "bearing"; "Kalman"; "embedding"; "confidence"; "bbox"; "doa" ]

let () =
  Alcotest.run "audit_memory"
    [ ( "isolation",
        [ Alcotest.test_case "fts cannot escape filter" `Quick
            test_fts_query_cannot_escape_the_participant_filter;
          Alcotest.test_case "odd person id" `Quick test_odd_person_id_does_not_widen_scope;
          Alcotest.test_case "projector one profile only" `Quick
            test_projector_renders_only_the_given_profile ] );
      ( "profiles",
        [ Alcotest.test_case "delete removes file" `Quick
            test_delete_person_removes_profile_from_disk;
          Alcotest.test_case "traversal refused" `Quick test_traversal_shapes_all_refused;
          Alcotest.test_case "no temp left" `Quick test_no_temp_file_left_after_write ] );
      ( "projector bounds",
        [ Alcotest.test_case "bounded under load" `Quick
            test_projector_bounded_under_all_large_inputs;
          Alcotest.test_case "no internals under load" `Quick test_no_internals_leak_under_load ] )
    ]
