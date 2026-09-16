open Bob_types

let at ms = Time.of_ms ms
let fixture = "fixtures/screwdriver.trace"

let parse_fixture () =
  match Bob_trace.parse_file fixture with
  | Ok evs -> evs
  | Error m -> Alcotest.failf "parse failed: %s" m

let test_parses_the_fixture () =
  Alcotest.(check int) "six events" 6 (List.length (parse_fixture ()))

let test_parses_timestamps_as_seconds () =
  match parse_fixture () with
  | e :: _ -> Alcotest.(check (float 0.01)) "t=0" 0. (Bob_events.at e |> Time.to_ms)
  | [] -> Alcotest.fail "empty"

let test_parses_quoted_text_with_spaces () =
  let evs = parse_fixture () in
  let has_full_question =
    List.exists
      (function
        | Bob_events.Utterance u -> u.text = "Bob where did I put the screwdriver?"
        | _ -> false)
      evs
  in
  Alcotest.(check bool) "full text" true has_full_question

let test_rejects_malformed_line () =
  match Bob_trace.parse_string "t=0.000 no_such_event" with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected a parse error"

let test_ignores_comments_and_blanks () =
  match Bob_trace.parse_string "# hi\n\nt=0.000 speech_ended\n" with
  | Ok [ _ ] -> ()
  | Ok l -> Alcotest.failf "expected 1 event, got %d" (List.length l)
  | Error m -> Alcotest.failf "unexpected error: %s" m

let run_replay ?brain_reply ?brain_fails_after evs =
  let sim =
    Bob_handler_sim.create ~start:(at 0.) ?brain_reply ?brain_fails_after ()
  in
  let r = ref None in
  Bob_runtime.run_sim sim (fun _sw -> r := Some (Bob_trace.replay evs));
  (sim, Option.get !r)

(* The end-to-end Phase 0 acceptance check. *)
let test_replay_produces_orientation_then_speech () =
  let evs = parse_fixture () in
  let sim, r = run_replay ~brain_reply:"I think it is on the desk." evs in
  (* Bob moved before he spoke. *)
  let moved =
    List.filter (function Bob_handler_sim.Looked _ -> true | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  let spoken =
    List.filter (function Bob_handler_sim.Spoke _ -> true | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  Alcotest.(check bool) "moved" true (List.length moved > 0);
  Alcotest.(check bool) "spoke" true (List.length spoken > 0);
  Alcotest.(check bool) "reflex recorded" true
    (Bob_obs.span r.Bob_trace.obs Bob_obs.Speech_start Bob_obs.Movement_start <> None)

let test_replay_orients_before_the_utterance_is_final () =
  let _sim, r = run_replay (parse_fixture ()) in
  let move_at = Bob_obs.span r.Bob_trace.obs Bob_obs.Speech_start Bob_obs.Movement_start in
  (* Movement happened at the speech-start instant, not 1.5 s later. *)
  match move_at with
  | Some ms -> Alcotest.(check bool) "immediate" true (ms < 100.)
  | None -> Alcotest.fail "no movement recorded"

let test_replay_is_deterministic () =
  let run () =
    let sim, _r = run_replay (parse_fixture ()) in
    List.length
      (List.filter (function Bob_handler_sim.Looked _ -> true | _ -> false)
         (Bob_handler_sim.actions sim))
  in
  Alcotest.(check int) "same both times" (run ()) (run ())

let test_brain_failure_does_not_crash_replay () =
  let sim, r = run_replay ~brain_fails_after:0 (parse_fixture ()) in
  let spoken =
    List.filter (function Bob_handler_sim.Spoke _ -> true | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  Alcotest.(check int) "said nothing" 0 (List.length spoken);
  Alcotest.(check bool) "error recorded" true (List.length r.Bob_trace.errors > 0)

let () =
  Alcotest.run "trace"
    [ ("parsing",
       [ Alcotest.test_case "fixture" `Quick test_parses_the_fixture;
         Alcotest.test_case "timestamps" `Quick test_parses_timestamps_as_seconds;
         Alcotest.test_case "quoted text" `Quick test_parses_quoted_text_with_spaces;
         Alcotest.test_case "malformed" `Quick test_rejects_malformed_line;
         Alcotest.test_case "comments" `Quick test_ignores_comments_and_blanks ]);
      ("replay",
       [ Alcotest.test_case "orient then speak" `Quick
           test_replay_produces_orientation_then_speech;
         Alcotest.test_case "reacts before understanding" `Quick
           test_replay_orients_before_the_utterance_is_final;
         Alcotest.test_case "deterministic" `Quick test_replay_is_deterministic;
         Alcotest.test_case "brain failure is contained" `Quick
           test_brain_failure_does_not_crash_replay ]) ]
