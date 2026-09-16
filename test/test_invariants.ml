open Bob_types

let at ms = Time.of_ms ms
let ttl = Bob_world.default_ttl
let ccfg = Bob_control.default_config

let with_store f =
  let dir = Filename.temp_file "bob_inv_" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let s = Bob_memory.open_store ~dir in
  Fun.protect ~finally:(fun () -> Bob_memory.close s) (fun () -> f s)

(* 1. An unknown track cannot load an arbitrary known person's memory. *)
let test_unknown_track_loads_no_profile () =
  with_store (fun s ->
      Bob_memory.write_profile s (Person_id.v "gustaf") "# Gustaf\n- secret\n";
      let w =
        Bob_world.apply (Bob_world.empty ~ttl)
          (Bob_events.Person_entered
             { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 0. })
      in
      (* The track has no identity, so there is no person to key a read by. *)
      Alcotest.(check bool) "no identity" true
        (Bob_world.identity_of ~now:(at 10.) w (Track_id.v 7) = None);
      let ctx =
        Bob_project.render ~now:(at 10.) ~world:w
          ~workspace:(Bob_workspace.empty ~config:Bob_workspace.default_config)
          ~profile:None ~episodes:[]
      in
      let contains h n =
        let nl = String.length n and hl = String.length h in
        let rec go i = i + nl <= hl && (String.sub h i nl = n || go (i + 1)) in
        nl = 0 || go 0
      in
      Alcotest.(check bool) "no leaked secret" false (contains ctx "secret"))

(* 2. A stale track cannot remain the active speaker forever. *)
let test_stale_track_stops_being_speaker () =
  let w =
    Bob_world.apply (Bob_world.empty ~ttl)
      (Bob_events.Person_entered
         { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-30.) })
  in
  let w = Bob_world.set_speaker ~at:(at 0.) ~confidence:(Confidence.v 0.9) w (Track_id.v 7) in
  Alcotest.(check bool) "speaker fresh" true (Bob_world.speaker_track ~now:(at 100.) w <> None);
  Alcotest.(check bool) "speaker expired" true
    (Bob_world.speaker_track ~now:(at 60_000.) w = None)

(* 3. A low-confidence face match cannot silently become a durable identity. *)
let test_low_confidence_does_not_preload_a_profile () =
  let e =
    Bob_events.Person_identified
      { at = at 0.; track = Track_id.v 7; person = Person_id.v "gustaf";
        confidence = Confidence.v 0.2 }
  in
  let w =
    List.fold_left Bob_world.apply (Bob_world.empty ~ttl)
      [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 0. }; e ]
  in
  let ds =
    Bob_control.decide ~config:ccfg ~now:(at 10.) ~world:w
      ~workspace:(Bob_workspace.empty ~config:Bob_workspace.default_config) e
  in
  Alcotest.(check bool) "no preload" false
    (List.exists (function Bob_control.Preload_profile _ -> true | _ -> false) ds)

(* 4. The LLM cannot directly actuate a motor. *)
let test_llm_cannot_exceed_mechanical_limits () =
  List.iter
    (fun (yaw, pitch) ->
      let a = Bob_control.Look_at { yaw = Angle.deg yaw; pitch = Angle.deg pitch } in
      match Bob_control.validate ~config:ccfg a with
      | Error _ -> ()
      | Ok _ -> Alcotest.failf "accepted out-of-range pose %.0f/%.0f" yaw pitch)
    [ (120., 0.); (-120., 0.); (0., 60.); (0., -60.) ]

let test_every_brain_action_passes_through_validate () =
  (* A Say the brain proposes is only spoken if validate approves it. *)
  let sim =
    Bob_handler_sim.create ~start:(at 0.)
      ~brain_reply:(String.make (ccfg.Bob_control.max_say_chars + 1) 'x') ()
  in
  let evs =
    [ Bob_events.Utterance
        { at = at 0.; text = "hej"; speaker = Some (Person_id.v "gustaf");
          speaker_track = None; language = Some "sv" } ]
  in
  let r = ref None in
  Bob_runtime.run_sim sim (fun _sw -> r := Some (Bob_trace.replay evs));
  let r = Option.get !r in
  let spoken =
    List.filter (function Bob_handler_sim.Spoke _ -> true | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  Alcotest.(check int) "overlong speech blocked" 0 (List.length spoken);
  Alcotest.(check bool) "rejection recorded" true (List.length r.Bob_trace.errors > 0)

(* 5. An expired perceptual location cannot masquerade as a current fact. *)
let test_expired_bearing_is_not_reported () =
  let w =
    Bob_world.apply (Bob_world.empty ~ttl)
      (Bob_events.Person_entered
         { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-29.) })
  in
  Alcotest.(check bool) "fresh" true (Bob_world.bearing_of ~now:(at 100.) w (Track_id.v 7) <> None);
  Alcotest.(check bool) "expired" true
    (Bob_world.bearing_of ~now:(at 60_000.) w (Track_id.v 7) = None)

(* 6. One person's memory never reaches another's context. *)
let test_memory_isolation_end_to_end () =
  with_store (fun s ->
      Bob_memory.write_profile s (Person_id.v "gustaf") "# Gustaf\n- likes screwdrivers\n";
      Bob_memory.write_profile s (Person_id.v "olle") "# Olle\n- likes dinosaurs\n";
      let ctx =
        Bob_project.render ~now:(at 0.) ~world:(Bob_world.empty ~ttl)
          ~workspace:(Bob_workspace.empty ~config:Bob_workspace.default_config)
          ~profile:(Bob_memory.read_profile s (Person_id.v "olle"))
          ~episodes:[]
      in
      let contains h n =
        let nl = String.length n and hl = String.length h in
        let rec go i = i + nl <= hl && (String.sub h i nl = n || go (i + 1)) in
        nl = 0 || go 0
      in
      Alcotest.(check bool) "olle present" true (contains ctx "dinosaurs");
      Alcotest.(check bool) "gustaf absent" false (contains ctx "screwdrivers"))

let () =
  Alcotest.run "invariants"
    [ ("SPEC section 30",
       [ Alcotest.test_case "unknown track loads nothing" `Quick test_unknown_track_loads_no_profile;
         Alcotest.test_case "stale speaker expires" `Quick test_stale_track_stops_being_speaker;
         Alcotest.test_case "low confidence is not durable" `Quick
           test_low_confidence_does_not_preload_a_profile;
         Alcotest.test_case "llm cannot exceed limits" `Quick
           test_llm_cannot_exceed_mechanical_limits;
         Alcotest.test_case "all actions validated" `Quick
           test_every_brain_action_passes_through_validate;
         Alcotest.test_case "expired location hidden" `Quick test_expired_bearing_is_not_reported;
         Alcotest.test_case "memory isolation" `Quick test_memory_isolation_end_to_end ]) ]
