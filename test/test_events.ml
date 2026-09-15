open Bob_types

let ev = Alcotest.testable Bob_events.pp Bob_events.equal

let roundtrip e =
  e |> Bob_events.to_json |> Yojson.Safe.to_string |> Yojson.Safe.from_string
  |> Bob_events.of_json

let test_roundtrip_speech_started () =
  let e =
    Bob_events.Speech_started
      { at = Time.of_ms 0.; doa = Some (Angle.deg (-31.));
        confidence = Confidence.v 0.8 }
  in
  Alcotest.(check (result ev string)) "roundtrip" (Ok e) (roundtrip e)

let test_roundtrip_person_identified () =
  let e =
    Bob_events.Person_identified
      { at = Time.of_ms 220.; track = Track_id.v 7;
        person = Person_id.v "gustaf"; confidence = Confidence.v 0.91 }
  in
  Alcotest.(check (result ev string)) "roundtrip" (Ok e) (roundtrip e)

let test_unknown_event_is_an_error_not_a_crash () =
  let bad = Yojson.Safe.from_string {|{"kind":"no_such_event","at":0}|} in
  match Bob_events.of_json bad with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected Error for unknown event kind"

let test_every_event_has_a_timestamp () =
  (* SPEC section 28: every event carries a monotonic timestamp. *)
  let e = Bob_events.Speech_ended { at = Time.of_ms 1500. } in
  Alcotest.(check (float 0.001)) "at" 1500. (Bob_events.at e |> Time.to_ms)

let () =
  Alcotest.run "events"
    [ ("roundtrip",
       [ Alcotest.test_case "speech_started" `Quick test_roundtrip_speech_started;
         Alcotest.test_case "person_identified" `Quick
           test_roundtrip_person_identified ]);
      ("errors",
       [ Alcotest.test_case "unknown kind" `Quick
           test_unknown_event_is_an_error_not_a_crash ]);
      ("timestamps",
       [ Alcotest.test_case "always present" `Quick
           test_every_event_has_a_timestamp ]) ]
