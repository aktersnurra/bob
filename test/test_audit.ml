(* Adversarial audit of the Phase 0 reducers. These are NOT from the plan:
   they probe whether the architecture actually holds, independently of the
   tests written alongside the implementation. *)

open Bob_types

let at ms = Time.of_ms ms
let ttl = Bob_world.default_ttl
let ccfg = Bob_control.default_config
let wscfg = Bob_workspace.default_config

(* 1. The headline product claim: orientation is emitted at the speech-start
   instant itself, with an EMPTY world and EMPTY workspace. If this needed any
   prior perception or cognition it would fail here. *)
let test_reflex_needs_nothing_but_the_event () =
  let e =
    Bob_events.Speech_started
      { at = at 0.; doa = Some (Angle.deg (-31.)); confidence = Confidence.v 0.8 }
  in
  let ds =
    Bob_control.decide ~config:ccfg ~now:(at 0.) ~world:(Bob_world.empty ~ttl)
      ~workspace:(Bob_workspace.empty ~config:wscfg) e
  in
  let looked =
    List.exists (function Bob_control.Look_at_angle _ -> true | _ -> false) ds
  in
  let thought =
    List.exists (function Bob_control.Invoke_brain _ -> true | _ -> false) ds
  in
  Alcotest.(check bool) "orients from a cold start" true looked;
  Alcotest.(check bool) "without thinking" false thought

(* 2. World/workspace divergence: after the SAME event stream and the SAME
   elapsed time, the world must have forgotten and the workspace must not. *)
let test_world_forgets_workspace_remembers () =
  let evs =
    [ Bob_events.Person_entered
        { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-29.) };
      Bob_events.Utterance
        { at = at 100.; text = "where is the screwdriver";
          speaker = Some (Person_id.v "gustaf"); speaker_track = None;
          language = Some "en" } ]
  in
  let w = List.fold_left Bob_world.apply (Bob_world.empty ~ttl) evs in
  let ws = List.fold_left Bob_workspace.apply (Bob_workspace.empty ~config:wscfg) evs in
  let later = at 30_000. in
  let w = Bob_world.expire ~now:later w in
  let ws = Bob_workspace.tick ~now:later ws in
  Alcotest.(check int) "world forgot the track" 0 (Bob_world.track_count w);
  Alcotest.(check bool) "workspace kept the speaker" true
    (Bob_workspace.speaker ws <> None)

(* 3. Replaying the same events twice must give identical state. Pure reducers. *)
let test_reducers_are_deterministic () =
  let evs =
    [ Bob_events.Person_entered
        { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 10. };
      Bob_events.Person_identified
        { at = at 10.; track = Track_id.v 7; person = Person_id.v "gustaf";
          confidence = Confidence.v 0.9 };
      Bob_events.Person_moved
        { at = at 20.; track = Track_id.v 7; bearing = Angle.deg 12. } ]
  in
  let run () =
    let w = List.fold_left Bob_world.apply (Bob_world.empty ~ttl) evs in
    ( Bob_world.track_count w,
      Bob_world.bearing_of ~now:(at 30.) w (Track_id.v 7) |> Option.map Angle.to_deg,
      Bob_world.identity_of ~now:(at 30.) w (Track_id.v 7)
      |> Option.map (fun (p, _) -> Person_id.to_string p) )
  in
  let a = run () and b = run () in
  Alcotest.(check bool) "identical" true (a = b)

(* 4. Event order must matter in the right way: a Person_left after an identify
   must not resurrect the track. *)
let test_left_beats_earlier_identify () =
  let w =
    List.fold_left Bob_world.apply (Bob_world.empty ~ttl)
      [ Bob_events.Person_entered
          { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 0. };
        Bob_events.Person_identified
          { at = at 10.; track = Track_id.v 7; person = Person_id.v "gustaf";
            confidence = Confidence.v 0.99 };
        Bob_events.Person_left { at = at 20.; track = Track_id.v 7 } ]
  in
  Alcotest.(check int) "gone" 0 (Bob_world.track_count w);
  Alcotest.(check bool) "no identity survives" true
    (Bob_world.identity_of ~now:(at 25.) w (Track_id.v 7) = None)

(* 5. An identity arriving for a track that was never seen must be ignored,
   not silently create a phantom track. *)
let test_identity_for_unknown_track_is_ignored () =
  let w =
    Bob_world.apply (Bob_world.empty ~ttl)
      (Bob_events.Person_identified
         { at = at 0.; track = Track_id.v 99; person = Person_id.v "gustaf";
           confidence = Confidence.v 0.99 })
  in
  Alcotest.(check int) "no phantom track" 0 (Bob_world.track_count w)

(* 6. Validation must be total: no action shape may slip through unvalidated.
   Probe the boundary values rather than the obviously-bad ones. *)
let test_validation_boundaries () =
  let ok a = match Bob_control.validate ~config:ccfg a with Ok _ -> true | Error _ -> false in
  (* exactly at the limit is allowed *)
  Alcotest.(check bool) "yaw at limit ok" true
    (ok (Bob_control.Look_at { yaw = Angle.deg 90.; pitch = Angle.deg 0. }));
  (* one degree past is not *)
  Alcotest.(check bool) "yaw past limit rejected" false
    (ok (Bob_control.Look_at { yaw = Angle.deg 91.; pitch = Angle.deg 0. }));
  Alcotest.(check bool) "pitch at limit ok" true
    (ok (Bob_control.Look_at { yaw = Angle.deg 0.; pitch = Angle.deg 30. }));
  Alcotest.(check bool) "pitch past limit rejected" false
    (ok (Bob_control.Look_at { yaw = Angle.deg 0.; pitch = Angle.deg 31. }));
  (* say at exactly max length is allowed, one over is not *)
  Alcotest.(check bool) "say at max ok" true
    (ok (Bob_control.Say (String.make ccfg.Bob_control.max_say_chars 'x')));
  Alcotest.(check bool) "say over max rejected" false
    (ok (Bob_control.Say (String.make (ccfg.Bob_control.max_say_chars + 1) 'x')))

(* 7. Angle normalisation must not let a wrapped angle sneak past the yaw limit.
   200 degrees normalises to -160, which is still outside +/-90 and must reject. *)
let test_wrapped_angle_still_rejected () =
  let a = Bob_control.Look_at { yaw = Angle.deg 200.; pitch = Angle.deg 0. } in
  match Bob_control.validate ~config:ccfg a with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "wrapped angle bypassed the yaw limit"

(* 8. Episode ids must be unique across closes, or consolidation would collide. *)
let test_episode_ids_are_unique () =
  let utter ms = Bob_events.Utterance
      { at = at ms; text = "hej"; speaker = Some (Person_id.v "gustaf");
        speaker_track = None; language = Some "sv" } in
  let ws = Bob_workspace.apply (Bob_workspace.empty ~config:wscfg) (utter 0.) in
  let id1 = Option.get (Bob_workspace.episode ws) in
  let ws = Bob_workspace.tick ~now:(at 601_000.) ws in
  let ws = Bob_workspace.apply ws (utter 602_000.) in
  let id2 = Option.get (Bob_workspace.episode ws) in
  let ws = Bob_workspace.tick ~now:(at 1_300_000.) ws in
  let ws = Bob_workspace.apply ws (utter 1_301_000.) in
  let id3 = Option.get (Bob_workspace.episode ws) in
  let s = List.map Episode_id.to_string [ id1; id2; id3 ] in
  Alcotest.(check int) "three distinct ids" 3
    (List.length (List.sort_uniq String.compare s))

(* 9. Regression: a Speech_started must not interrupt speech that was never
   playing. The replay driver must decide against the PRE-event world, or
   applying the event first sets speech_active and Bob interrupts himself. *)
let test_first_speech_does_not_self_interrupt () =
  let brain, _ = Bob_capability.Brain.fake () in
  let body, _ = Bob_capability.Body.fake () in
  let tts, tts_log = Bob_capability.Tts.fake () in
  let evs =
    [ Bob_events.Speech_started
        { at = at 0.; doa = Some (Angle.deg (-31.)); confidence = Confidence.v 0.8 } ]
  in
  let _ = Bob_trace.replay ~brain ~body ~tts ~memory:None evs in
  let _spoken, stops = tts_log () in
  Alcotest.(check int) "no spurious interrupt" 0 stops

(* 10. But a genuine barge-in MUST still interrupt: speech starts while Bob is
   already speaking. *)
let test_real_barge_in_still_interrupts () =
  let brain, _ = Bob_capability.Brain.fake () in
  let body, _ = Bob_capability.Body.fake () in
  let tts, tts_log = Bob_capability.Tts.fake () in
  let evs =
    [ (* Bob is speaking from t=0 *)
      Bob_events.Speech_started
        { at = at 0.; doa = Some (Angle.deg 0.); confidence = Confidence.v 0.8 };
      (* ...and is still speaking when someone barges in at t=500 *)
      Bob_events.Speech_started
        { at = at 500.; doa = Some (Angle.deg 40.); confidence = Confidence.v 0.9 } ]
  in
  let _ = Bob_trace.replay ~brain ~body ~tts ~memory:None evs in
  let _spoken, stops = tts_log () in
  Alcotest.(check int) "second onset interrupts" 1 stops

let () =
  Alcotest.run "audit"
    [ ("architecture",
       [ Alcotest.test_case "reflex from cold start" `Quick
           test_reflex_needs_nothing_but_the_event;
         Alcotest.test_case "world forgets, workspace remembers" `Quick
           test_world_forgets_workspace_remembers;
         Alcotest.test_case "deterministic" `Quick test_reducers_are_deterministic ]);
      ("world edge cases",
       [ Alcotest.test_case "left beats identify" `Quick test_left_beats_earlier_identify;
         Alcotest.test_case "no phantom tracks" `Quick
           test_identity_for_unknown_track_is_ignored ]);
      ("validation",
       [ Alcotest.test_case "boundaries" `Quick test_validation_boundaries;
         Alcotest.test_case "wrapped angle" `Quick test_wrapped_angle_still_rejected ]);
      ("workspace",
       [ Alcotest.test_case "unique episode ids" `Quick test_episode_ids_are_unique ]) ;
      ("interruption",
       [ Alcotest.test_case "no self-interrupt" `Quick
           test_first_speech_does_not_self_interrupt;
         Alcotest.test_case "real barge-in works" `Quick
           test_real_barge_in_still_interrupts ]) ]
