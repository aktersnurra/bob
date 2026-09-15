let test_confidence_clamps () =
  Alcotest.(check (float 0.001)) "above 1 clamps"
    1.0 (Bob_types.Confidence.v 1.5 |> Bob_types.Confidence.to_float);
  Alcotest.(check (float 0.001)) "below 0 clamps"
    0.0 (Bob_types.Confidence.v (-0.2) |> Bob_types.Confidence.to_float)

let test_ids_are_opaque_and_stable () =
  let p = Bob_types.Person_id.v "gustaf" in
  Alcotest.(check string) "roundtrip" "gustaf" (Bob_types.Person_id.to_string p);
  let t1 = Bob_types.Track_id.v 7 in
  let t2 = Bob_types.Track_id.v 7 in
  Alcotest.(check bool) "same track equal" true (Bob_types.Track_id.equal t1 t2)

let test_observation_carries_provenance () =
  let t = Bob_types.Time.of_ms 1000. in
  let o =
    Bob_types.Observation.
      { value = 42; confidence = Bob_types.Confidence.v 0.9;
        observed_at = t; source = Vision }
  in
  Alcotest.(check int) "value" 42 o.Bob_types.Observation.value;
  Alcotest.(check bool) "source is vision" true
    (o.Bob_types.Observation.source = Bob_types.Observation.Vision)

let test_angle_normalises () =
  Alcotest.(check (float 0.01)) "190 wraps to -170"
    (-170.) (Bob_types.Angle.deg 190. |> Bob_types.Angle.to_deg);
  Alcotest.(check (float 0.01)) "-190 wraps to 170"
    170. (Bob_types.Angle.deg (-190.) |> Bob_types.Angle.to_deg)

let () =
  Alcotest.run "types"
    [ ("confidence", [ Alcotest.test_case "clamps" `Quick test_confidence_clamps ]);
      ("ids", [ Alcotest.test_case "opaque" `Quick test_ids_are_opaque_and_stable ]);
      ("observation",
       [ Alcotest.test_case "provenance" `Quick test_observation_carries_provenance ]);
      ("angle", [ Alcotest.test_case "normalises" `Quick test_angle_normalises ]) ]
