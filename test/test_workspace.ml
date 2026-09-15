open Bob_types

let at ms = Time.of_ms ms
let cfg = Bob_workspace.default_config

let utter ms text speaker =
  Bob_events.Utterance
    { at = at ms; text; speaker = Option.map Person_id.v speaker;
      speaker_track = None; language = Some "en" }

let apply_all ws evs = List.fold_left Bob_workspace.apply ws evs

let test_utterance_opens_an_episode () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej bob" (Some "gustaf") ] in
  Alcotest.(check bool) "episode open" true (Bob_workspace.episode ws <> None)

let test_speaker_is_recorded () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  match Bob_workspace.speaker ws with
  | Some p -> Alcotest.(check string) "gustaf" "gustaf" (Person_id.to_string p)
  | None -> Alcotest.fail "expected a speaker"

(* THE key property of SPEC section 15. *)
let test_speaker_survives_perceptual_expiry () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  (* A full minute later, long past any world TTL, the workspace still knows. *)
  let ws = Bob_workspace.tick ~now:(at 60_000.) ws in
  Alcotest.(check bool) "speaker retained" true (Bob_workspace.speaker ws <> None)

let test_recent_turns_are_bounded () =
  let evs = List.init 50 (fun i -> utter (float_of_int i *. 10.) "x" (Some "gustaf")) in
  let ws = apply_all (Bob_workspace.empty ~config:cfg) evs in
  Alcotest.(check bool) "bounded" true
    (List.length (Bob_workspace.recent_turns ws) <= cfg.Bob_workspace.max_turns)

let test_turns_are_in_chronological_order () =
  let ws =
    apply_all (Bob_workspace.empty ~config:cfg)
      [ utter 0. "first" (Some "gustaf"); utter 10. "second" (Some "gustaf") ]
  in
  match Bob_workspace.recent_turns ws with
  | [ a; b ] ->
      Alcotest.(check string) "first" "first" a.Bob_workspace.text;
      Alcotest.(check string) "second" "second" b.Bob_workspace.text
  | l -> Alcotest.failf "expected 2 turns, got %d" (List.length l)

let test_episode_closes_after_inactivity () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  let still_open = Bob_workspace.tick ~now:(at 60_000.) ws in
  Alcotest.(check bool) "open at 1min" true (Bob_workspace.episode still_open <> None);
  let closed = Bob_workspace.tick ~now:(at 601_000.) ws in
  Alcotest.(check bool) "closed past 10min" true (Bob_workspace.episode closed = None)

let test_closing_an_episode_clears_conversation_state () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  let closed = Bob_workspace.tick ~now:(at 601_000.) ws in
  Alcotest.(check bool) "speaker cleared" true (Bob_workspace.speaker closed = None);
  Alcotest.(check int) "turns cleared" 0 (List.length (Bob_workspace.recent_turns closed))

let test_closed_episode_is_emitted_once_for_consolidation () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  let closed, finished = Bob_workspace.tick_with_closed ~now:(at 601_000.) ws in
  Alcotest.(check bool) "one finished episode" true (finished <> None);
  let _, again = Bob_workspace.tick_with_closed ~now:(at 602_000.) closed in
  Alcotest.(check bool) "not emitted twice" true (again = None)

let test_new_utterance_after_close_starts_a_new_episode () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  let first_id = Option.get (Bob_workspace.episode ws) in
  let closed = Bob_workspace.tick ~now:(at 601_000.) ws in
  let reopened = Bob_workspace.apply closed (utter 602_000. "hej igen" (Some "gustaf")) in
  let second_id = Option.get (Bob_workspace.episode reopened) in
  Alcotest.(check bool) "different episode" true
    (Episode_id.to_string first_id <> Episode_id.to_string second_id)

let test_topic_and_goal_can_be_set_and_persist () =
  let ws = apply_all (Bob_workspace.empty ~config:cfg) [ utter 0. "hej" (Some "gustaf") ] in
  let ws = Bob_workspace.set_topic ws (Some "screwdriver") in
  let ws = Bob_workspace.tick ~now:(at 60_000.) ws in
  Alcotest.(check (option string)) "topic held" (Some "screwdriver") (Bob_workspace.topic ws)

let () =
  Alcotest.run "workspace"
    [ ("episode",
       [ Alcotest.test_case "opens" `Quick test_utterance_opens_an_episode;
         Alcotest.test_case "closes on inactivity" `Quick test_episode_closes_after_inactivity;
         Alcotest.test_case "close clears state" `Quick
           test_closing_an_episode_clears_conversation_state;
         Alcotest.test_case "emitted once" `Quick
           test_closed_episode_is_emitted_once_for_consolidation;
         Alcotest.test_case "reopens fresh" `Quick
           test_new_utterance_after_close_starts_a_new_episode ]);
      ("speaker",
       [ Alcotest.test_case "recorded" `Quick test_speaker_is_recorded;
         Alcotest.test_case "survives expiry" `Quick
           test_speaker_survives_perceptual_expiry ]);
      ("turns",
       [ Alcotest.test_case "bounded" `Quick test_recent_turns_are_bounded;
         Alcotest.test_case "ordered" `Quick test_turns_are_in_chronological_order ]);
      ("topic", [ Alcotest.test_case "persists" `Quick test_topic_and_goal_can_be_set_and_persist ]) ]
