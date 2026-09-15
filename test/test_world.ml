open Bob_types

let ttl = Bob_world.default_ttl

let at ms = Time.of_ms ms

let enter ms track bearing =
  Bob_events.Person_entered
    { at = at ms; track = Track_id.v track; bearing = Angle.deg bearing }

let identify ms track person c =
  Bob_events.Person_identified
    { at = at ms; track = Track_id.v track; person = Person_id.v person;
      confidence = Confidence.v c }

let apply_all w evs = List.fold_left Bob_world.apply w evs

let test_track_appears () =
  let w = apply_all (Bob_world.empty ~ttl) [ enter 0. 7 (-29.) ] in
  Alcotest.(check int) "one track" 1
    (List.length (Bob_world.visible_tracks ~now:(at 100.) w))

let test_track_expires_when_stale () =
  let w = apply_all (Bob_world.empty ~ttl) [ enter 0. 7 (-29.) ] in
  let fresh = Bob_world.visible_tracks ~now:(at 100.) w in
  let stale = Bob_world.visible_tracks ~now:(at 60_000.) w in
  Alcotest.(check int) "fresh" 1 (List.length fresh);
  Alcotest.(check int) "stale is gone" 0 (List.length stale)

let test_bearing_is_none_when_stale () =
  let w = apply_all (Bob_world.empty ~ttl) [ enter 0. 7 (-29.) ] in
  let t = Track_id.v 7 in
  Alcotest.(check bool) "fresh bearing present" true
    (Bob_world.bearing_of ~now:(at 100.) w t <> None);
  Alcotest.(check bool) "stale bearing absent" true
    (Bob_world.bearing_of ~now:(at 60_000.) w t = None)

let test_person_left_removes_track () =
  let w =
    apply_all (Bob_world.empty ~ttl)
      [ enter 0. 7 (-29.);
        Bob_events.Person_left { at = at 50.; track = Track_id.v 7 } ]
  in
  Alcotest.(check int) "gone" 0
    (List.length (Bob_world.visible_tracks ~now:(at 60.) w))

let test_identity_attaches_to_track () =
  let w = apply_all (Bob_world.empty ~ttl) [ enter 0. 7 (-29.); identify 20. 7 "gustaf" 0.9 ] in
  match Bob_world.identity_of ~now:(at 100.) w (Track_id.v 7) with
  | Some (p, _c) ->
      Alcotest.(check string) "gustaf" "gustaf" (Person_id.to_string p)
  | None -> Alcotest.fail "expected an identity"

let test_higher_confidence_identity_wins () =
  let w =
    apply_all (Bob_world.empty ~ttl)
      [ enter 0. 7 (-29.); identify 20. 7 "olle" 0.5; identify 30. 7 "gustaf" 0.9 ]
  in
  match Bob_world.identity_of ~now:(at 100.) w (Track_id.v 7) with
  | Some (p, _) -> Alcotest.(check string) "gustaf" "gustaf" (Person_id.to_string p)
  | None -> Alcotest.fail "expected an identity"

let test_lower_confidence_does_not_overwrite () =
  let w =
    apply_all (Bob_world.empty ~ttl)
      [ enter 0. 7 (-29.); identify 20. 7 "gustaf" 0.9; identify 30. 7 "olle" 0.4 ]
  in
  match Bob_world.identity_of ~now:(at 100.) w (Track_id.v 7) with
  | Some (p, _) -> Alcotest.(check string) "still gustaf" "gustaf" (Person_id.to_string p)
  | None -> Alcotest.fail "expected an identity"

let test_expire_prunes_state () =
  let w = apply_all (Bob_world.empty ~ttl) [ enter 0. 7 (-29.) ] in
  let pruned = Bob_world.expire ~now:(at 60_000.) w in
  Alcotest.(check int) "pruned" 0 (Bob_world.track_count pruned)

let test_doa_is_recorded_and_expires_fast () =
  let w =
    apply_all (Bob_world.empty ~ttl)
      [ Bob_events.Speech_direction
          { at = at 0.; doa = Angle.deg (-31.); confidence = Confidence.v 0.8 } ]
  in
  Alcotest.(check bool) "fresh doa" true (Bob_world.last_doa ~now:(at 100.) w <> None);
  Alcotest.(check bool) "stale doa" true
    (Bob_world.last_doa ~now:(at 10_000.) w = None)

(* Property: applying any event list then expiring far in the future always
   leaves an empty world. Nothing sensor-derived is immortal. *)
let prop_everything_expires =
  let gen_event =
    QCheck2.Gen.(
      oneof
        [ map2 (fun t b -> enter 0. t b) (int_range 1 5) (float_range (-90.) 90.);
          map (fun t -> Bob_events.Person_left { at = at 0.; track = Track_id.v t })
            (int_range 1 5) ])
  in
  QCheck2.Test.make ~name:"everything expires" ~count:200
    (QCheck2.Gen.list_size (QCheck2.Gen.int_range 0 20) gen_event) (fun evs ->
      let w = apply_all (Bob_world.empty ~ttl) evs in
      let w = Bob_world.expire ~now:(at 1_000_000.) w in
      Bob_world.track_count w = 0 && Bob_world.last_doa ~now:(at 1_000_000.) w = None)

let () =
  Alcotest.run "world"
    [ ("tracks",
       [ Alcotest.test_case "appears" `Quick test_track_appears;
         Alcotest.test_case "expires" `Quick test_track_expires_when_stale;
         Alcotest.test_case "bearing stale" `Quick test_bearing_is_none_when_stale;
         Alcotest.test_case "left removes" `Quick test_person_left_removes_track;
         Alcotest.test_case "expire prunes" `Quick test_expire_prunes_state ]);
      ("identity",
       [ Alcotest.test_case "attaches" `Quick test_identity_attaches_to_track;
         Alcotest.test_case "higher wins" `Quick test_higher_confidence_identity_wins;
         Alcotest.test_case "lower loses" `Quick test_lower_confidence_does_not_overwrite ]);
      ("audio", [ Alcotest.test_case "doa" `Quick test_doa_is_recorded_and_expires_fast ]);
      ("props", List.map QCheck_alcotest.to_alcotest [ prop_everything_expires ]) ]
