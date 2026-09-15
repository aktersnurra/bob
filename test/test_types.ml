let test_confidence_clamps () =
  Alcotest.(check (float 0.001)) "above 1 clamps"
    1.0 (Bob_types.Confidence.v 1.5 |> Bob_types.Confidence.to_float);
  Alcotest.(check (float 0.001)) "below 0 clamps"
    0.0 (Bob_types.Confidence.v (-0.2) |> Bob_types.Confidence.to_float)

let () =
  Alcotest.run "types"
    [ ("confidence", [ Alcotest.test_case "clamps" `Quick test_confidence_clamps ]) ]
