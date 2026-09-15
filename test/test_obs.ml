open Bob_types

let at ms = Time.of_ms ms

let test_records_a_span () =
  let t = Bob_obs.empty () in
  let t = Bob_obs.mark t ~at:(at 0.) Bob_obs.Speech_start in
  let t = Bob_obs.mark t ~at:(at 80.) Bob_obs.Movement_start in
  Alcotest.(check (option (float 0.01))) "reflex" (Some 80.)
    (Bob_obs.span t Bob_obs.Speech_start Bob_obs.Movement_start)

let test_missing_mark_gives_none () =
  let t = Bob_obs.mark (Bob_obs.empty ()) ~at:(at 0.) Bob_obs.Speech_start in
  Alcotest.(check (option (float 0.01))) "none" None
    (Bob_obs.span t Bob_obs.Speech_start Bob_obs.First_audio)

let test_report_lists_the_spec_spans () =
  let t = Bob_obs.empty () in
  let t = Bob_obs.mark t ~at:(at 0.) Bob_obs.Speech_start in
  let t = Bob_obs.mark t ~at:(at 80.) Bob_obs.Movement_start in
  let t = Bob_obs.mark t ~at:(at 1500.) Bob_obs.Speech_end in
  let t = Bob_obs.mark t ~at:(at 1700.) Bob_obs.Stt_final in
  let t = Bob_obs.mark t ~at:(at 2100.) Bob_obs.Llm_first_token in
  let t = Bob_obs.mark t ~at:(at 2300.) Bob_obs.First_audio in
  let r = Bob_obs.report t in
  (* SPEC section 28 names exactly these four. *)
  Alcotest.(check bool) "reflex line" true
    (List.exists (fun (n, _) -> n = "speech-start -> movement-start") r);
  Alcotest.(check bool) "stt line" true
    (List.exists (fun (n, _) -> n = "speech-end -> stt-final") r);
  Alcotest.(check bool) "llm line" true
    (List.exists (fun (n, _) -> n = "speech-end -> llm-first-token") r);
  Alcotest.(check bool) "audio line" true
    (List.exists (fun (n, _) -> n = "speech-end -> first-audio") r)

let test_reflex_budget_is_flagged_when_exceeded () =
  let t = Bob_obs.empty () in
  let t = Bob_obs.mark t ~at:(at 0.) Bob_obs.Speech_start in
  let t = Bob_obs.mark t ~at:(at 250.) Bob_obs.Movement_start in
  Alcotest.(check bool) "over budget" true
    (Bob_obs.over_budget t |> List.exists (fun (n, _, _) -> n = "speech-start -> movement-start"))

let test_within_budget_is_not_flagged () =
  let t = Bob_obs.empty () in
  let t = Bob_obs.mark t ~at:(at 0.) Bob_obs.Speech_start in
  let t = Bob_obs.mark t ~at:(at 50.) Bob_obs.Movement_start in
  Alcotest.(check int) "nothing flagged" 0 (List.length (Bob_obs.over_budget t))


(* Out-of-order marks must be reported as invalid, not printed as a number.
   A final transcript cannot precede the end of speech. *)
let test_negative_span_is_flagged_out_of_order () =
  let t = Bob_obs.empty () in
  let t = Bob_obs.mark t ~at:(at 1680.) Bob_obs.Stt_final in
  let t = Bob_obs.mark t ~at:(at 1700.) Bob_obs.Speech_end in
  Alcotest.(check bool) "flagged" true
    (Bob_obs.out_of_order t
     |> List.exists (fun (n, _) -> n = "speech-end -> stt-final"));
  let s = Format.asprintf "%a" Bob_obs.pp_report t in
  let contains h n =
    let nl = String.length n and hl = String.length h in
    let rec go i = i + nl <= hl && (String.sub h i nl = n || go (i + 1)) in
    nl = 0 || go 0
  in
  Alcotest.(check bool) "printed as INVALID" true (contains s "INVALID")

let test_well_ordered_spans_are_not_flagged () =
  let t = Bob_obs.empty () in
  let t = Bob_obs.mark t ~at:(at 1500.) Bob_obs.Speech_end in
  let t = Bob_obs.mark t ~at:(at 1680.) Bob_obs.Stt_final in
  Alcotest.(check int) "none flagged" 0 (List.length (Bob_obs.out_of_order t))

let () =
  Alcotest.run "obs"
    [ ("spans",
       [ Alcotest.test_case "records" `Quick test_records_a_span;
         Alcotest.test_case "missing" `Quick test_missing_mark_gives_none ]);
      ("report", [ Alcotest.test_case "spec spans" `Quick test_report_lists_the_spec_spans ]);
      ("ordering",
       [ Alcotest.test_case "negative flagged" `Quick
           test_negative_span_is_flagged_out_of_order;
         Alcotest.test_case "positive not flagged" `Quick
           test_well_ordered_spans_are_not_flagged ]);
      ("budgets",
       [ Alcotest.test_case "flags over" `Quick test_reflex_budget_is_flagged_when_exceeded;
         Alcotest.test_case "allows under" `Quick test_within_budget_is_not_flagged ]) ]
