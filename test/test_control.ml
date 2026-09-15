open Bob_types

let at ms = Time.of_ms ms
let ttl = Bob_world.default_ttl
let ccfg = Bob_control.default_config

let world_with evs = List.fold_left Bob_world.apply (Bob_world.empty ~ttl) evs
let ws_with evs = List.fold_left Bob_workspace.apply
    (Bob_workspace.empty ~config:Bob_workspace.default_config) evs

let decide ~now ~world ~ws ev =
  Bob_control.decide ~config:ccfg ~now ~world ~workspace:ws ev

let has_look ds =
  List.exists (function Bob_control.Look_at_angle _ -> true | _ -> false) ds

let has_invoke ds =
  List.exists (function Bob_control.Invoke_brain _ -> true | _ -> false) ds

(* SPEC section 34: react before understanding. *)
let test_speech_start_orients_immediately () =
  let e =
    Bob_events.Speech_started
      { at = at 0.; doa = Some (Angle.deg (-31.)); confidence = Confidence.v 0.8 }
  in
  let ds = decide ~now:(at 0.) ~world:(world_with [ e ]) ~ws:(ws_with []) e in
  Alcotest.(check bool) "orients" true (has_look ds);
  Alcotest.(check bool) "does not call the brain" false (has_invoke ds)

let test_speech_start_without_doa_does_not_orient () =
  let e =
    Bob_events.Speech_started { at = at 0.; doa = None; confidence = Confidence.v 0.8 }
  in
  let ds = decide ~now:(at 0.) ~world:(world_with [ e ]) ~ws:(ws_with []) e in
  Alcotest.(check bool) "no blind movement" false (has_look ds)

let test_brain_is_invoked_only_on_final_utterance () =
  let partial = Bob_events.Partial_utterance { at = at 400.; text = "Bob where..." } in
  let ds = decide ~now:(at 400.) ~world:(world_with []) ~ws:(ws_with []) partial in
  Alcotest.(check bool) "no brain on partial" false (has_invoke ds);
  let final =
    Bob_events.Utterance
      { at = at 1500.; text = "Bob where is the screwdriver?";
        speaker = Some (Person_id.v "gustaf"); speaker_track = None;
        language = Some "en" }
  in
  let ds = decide ~now:(at 1500.) ~world:(world_with []) ~ws:(ws_with [ final ]) final in
  Alcotest.(check bool) "brain on final" true (has_invoke ds)

let test_no_interaction_means_no_brain () =
  let e = Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 10. } in
  let ds = decide ~now:(at 0.) ~world:(world_with [ e ]) ~ws:(ws_with []) e in
  Alcotest.(check bool) "idle presence does not think" false (has_invoke ds)

let test_speaker_associated_to_nearest_track_by_doa () =
  let evs =
    [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-29.) };
      Bob_events.Person_entered { at = at 0.; track = Track_id.v 8; bearing = Angle.deg 40. } ]
  in
  let w = world_with evs in
  match Bob_control.associate_speaker ~config:ccfg ~now:(at 10.) ~world:w
          ~doa:(Angle.deg (-31.)) with
  | Some t -> Alcotest.(check int) "track 7" 7 (Track_id.to_int t)
  | None -> Alcotest.fail "expected an association"

let test_speaker_association_refuses_when_ambiguous () =
  (* Two tracks equidistant from the DoA: refuse rather than guess. *)
  let evs =
    [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-10.) };
      Bob_events.Person_entered { at = at 0.; track = Track_id.v 8; bearing = Angle.deg 10. } ]
  in
  let w = world_with evs in
  Alcotest.(check bool) "no guess" true
    (Bob_control.associate_speaker ~config:ccfg ~now:(at 10.) ~world:w
       ~doa:(Angle.deg 0.) = None)

let test_speaker_association_refuses_when_too_far () =
  let evs =
    [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-80.) } ]
  in
  let w = world_with evs in
  Alcotest.(check bool) "outside tolerance" true
    (Bob_control.associate_speaker ~config:ccfg ~now:(at 10.) ~world:w
       ~doa:(Angle.deg 70.) = None)

let test_stale_track_cannot_be_associated () =
  let evs = [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-30.) } ] in
  let w = world_with evs in
  Alcotest.(check bool) "stale track ignored" true
    (Bob_control.associate_speaker ~config:ccfg ~now:(at 60_000.) ~world:w
       ~doa:(Angle.deg (-31.)) = None)

let test_unknown_track_schedules_recognition () =
  let e = Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 5. } in
  let ds = decide ~now:(at 0.) ~world:(world_with [ e ]) ~ws:(ws_with []) e in
  Alcotest.(check bool) "recognise" true
    (List.exists (function Bob_control.Recognise _ -> true | _ -> false) ds)

let test_already_identified_track_does_not_reschedule () =
  let evs =
    [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg 5. };
      Bob_events.Person_identified
        { at = at 20.; track = Track_id.v 7; person = Person_id.v "gustaf";
          confidence = Confidence.v 0.95 } ]
  in
  let w = world_with evs in
  let ds = decide ~now:(at 30.) ~world:w ~ws:(ws_with []) (List.nth evs 1) in
  Alcotest.(check bool) "no re-recognition" false
    (List.exists (function Bob_control.Recognise _ -> true | _ -> false) ds)

(* SPEC section 30: the LLM cannot actuate hardware directly. *)
let test_validate_rejects_out_of_range_look () =
  let a = Bob_control.Look_at { yaw = Angle.deg 200.; pitch = Angle.deg 0. } in
  match Bob_control.validate ~config:ccfg a with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected rejection of out-of-range yaw"

let test_validate_clamps_pitch_within_limits () =
  let a = Bob_control.Look_at { yaw = Angle.deg 10.; pitch = Angle.deg 20. } in
  match Bob_control.validate ~config:ccfg a with
  | Ok (Bob_control.Look_at p) ->
      Alcotest.(check (float 0.01)) "yaw kept" 10. (Angle.to_deg p.yaw)
  | Ok _ -> Alcotest.fail "wrong action"
  | Error m -> Alcotest.failf "unexpected rejection: %s" m

let test_validate_rejects_empty_speech () =
  match Bob_control.validate ~config:ccfg (Bob_control.Say "") with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected rejection of empty speech"

let test_validate_rejects_overlong_speech () =
  let long = String.make (ccfg.Bob_control.max_say_chars + 1) 'x' in
  match Bob_control.validate ~config:ccfg (Bob_control.Say long) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected rejection of overlong speech"

let () =
  Alcotest.run "control"
    [ ("reflex",
       [ Alcotest.test_case "orients immediately" `Quick test_speech_start_orients_immediately;
         Alcotest.test_case "no doa no movement" `Quick
           test_speech_start_without_doa_does_not_orient ]);
      ("cognition",
       [ Alcotest.test_case "final only" `Quick test_brain_is_invoked_only_on_final_utterance;
         Alcotest.test_case "idle is silent" `Quick test_no_interaction_means_no_brain ]);
      ("association",
       [ Alcotest.test_case "nearest" `Quick test_speaker_associated_to_nearest_track_by_doa;
         Alcotest.test_case "ambiguous refuses" `Quick
           test_speaker_association_refuses_when_ambiguous;
         Alcotest.test_case "too far refuses" `Quick
           test_speaker_association_refuses_when_too_far;
         Alcotest.test_case "stale refuses" `Quick test_stale_track_cannot_be_associated ]);
      ("recognition",
       [ Alcotest.test_case "schedules" `Quick test_unknown_track_schedules_recognition;
         Alcotest.test_case "no duplicate" `Quick
           test_already_identified_track_does_not_reschedule ]);
      ("validation",
       [ Alcotest.test_case "range" `Quick test_validate_rejects_out_of_range_look;
         Alcotest.test_case "within limits" `Quick test_validate_clamps_pitch_within_limits;
         Alcotest.test_case "empty say" `Quick test_validate_rejects_empty_speech;
         Alcotest.test_case "long say" `Quick test_validate_rejects_overlong_speech ]) ]
