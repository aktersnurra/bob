open Bob_types

let at ms = Time.of_ms ms
let ttl = Bob_world.default_ttl

let contains haystack needle =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let base_world () =
  List.fold_left Bob_world.apply (Bob_world.empty ~ttl)
    [ Bob_events.Person_entered { at = at 0.; track = Track_id.v 7; bearing = Angle.deg (-29.) };
      Bob_events.Person_identified
        { at = at 20.; track = Track_id.v 7; person = Person_id.v "gustaf";
          confidence = Confidence.v 0.93 } ]

let base_ws () =
  List.fold_left Bob_workspace.apply
    (Bob_workspace.empty ~config:Bob_workspace.default_config)
    [ Bob_events.Utterance
        { at = at 100.; text = "Bob where is the screwdriver?";
          speaker = Some (Person_id.v "gustaf"); speaker_track = None;
          language = Some "en" } ]

let project ?(profile = None) ?(episodes = []) () =
  Bob_project.render ~now:(at 150.) ~world:(base_world ()) ~workspace:(base_ws ())
    ~profile ~episodes

let test_names_the_speaker () =
  Alcotest.(check bool) "names gustaf" true (contains (project ()) "Gustaf")

let test_includes_recent_conversation () =
  Alcotest.(check bool) "quotes the turn" true
    (contains (project ()) "screwdriver")

let test_includes_profile_when_given () =
  let s = project ~profile:(Some "- Prefers Swedish.") () in
  Alcotest.(check bool) "profile present" true (contains s "Prefers Swedish")

(* SPEC section 21: these must never reach the brain. *)
let test_excludes_internal_representations () =
  let s = project ~profile:(Some "- Prefers Swedish.") () in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool)
        (Printf.sprintf "excludes %S" forbidden)
        false (contains s forbidden))
    [ "track_7"; "track_"; "bearing"; "-29"; "confidence"; "0.93"; "embedding";
      "kalman"; "bbox" ]

let test_unknown_person_is_described_without_ids () =
  let w =
    Bob_world.apply (base_world ())
      (Bob_events.Person_entered { at = at 30.; track = Track_id.v 9; bearing = Angle.deg 40. })
  in
  let s = Bob_project.render ~now:(at 150.) ~world:w ~workspace:(base_ws ())
      ~profile:None ~episodes:[] in
  Alcotest.(check bool) "mentions someone unidentified" true
    (contains s "unidentified" || contains s "someone");
  Alcotest.(check bool) "still no ids" false (contains s "track_9")

let test_is_bounded_in_size () =
  let long_profile = String.concat "\n" (List.init 500 (fun i -> Printf.sprintf "- fact %d" i)) in
  let s = project ~profile:(Some long_profile) () in
  Alcotest.(check bool) "bounded" true (String.length s <= Bob_project.max_chars)

let test_empty_state_still_renders () =
  let s =
    Bob_project.render ~now:(at 0.) ~world:(Bob_world.empty ~ttl)
      ~workspace:(Bob_workspace.empty ~config:Bob_workspace.default_config)
      ~profile:None ~episodes:[]
  in
  Alcotest.(check bool) "non-empty" true (String.length s > 0)

let () =
  Alcotest.run "project"
    [ ("content",
       [ Alcotest.test_case "speaker" `Quick test_names_the_speaker;
         Alcotest.test_case "conversation" `Quick test_includes_recent_conversation;
         Alcotest.test_case "profile" `Quick test_includes_profile_when_given;
         Alcotest.test_case "unknown person" `Quick test_unknown_person_is_described_without_ids;
         Alcotest.test_case "empty" `Quick test_empty_state_still_renders ]);
      ("exclusions",
       [ Alcotest.test_case "no internals" `Quick test_excludes_internal_representations ]);
      ("bounds", [ Alcotest.test_case "size" `Quick test_is_bounded_in_size ]) ]
