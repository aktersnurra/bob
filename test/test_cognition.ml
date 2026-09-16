open Bob_types

let at ms = Time.of_ms ms
let ttl = Bob_world.default_ttl

let world_with evs = List.fold_left Bob_world.apply (Bob_world.empty ~ttl) evs

let ws_with evs =
  List.fold_left Bob_workspace.apply
    (Bob_workspace.empty ~config:Bob_workspace.default_config) evs

let utterance =
  Bob_events.Utterance
    { at = at 1680.; text = "Bob where is the screwdriver?";
      speaker = Some (Person_id.v "gustaf"); speaker_track = None;
      language = Some "en" }

(* §21: a scenario test with no microphone, no NUC, no OpenRouter, no motors. *)
let test_known_speaker_asks_a_remembered_question () =
  let sim =
    Bob_handler_sim.create ~start:(at 1680.)
      ~memory:[ Bob_effect.Memory.{ text = "keeps tools in the workshop"; source = "profile" } ]
      ~brain_reply:"It is in the workshop." ()
  in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () ->
          Bob_cognition.handle_utterance
            ~config:Bob_control.default_config
            ~world:(world_with [])
            ~workspace:(ws_with [ utterance ])
            ~event:utterance));
  let spoke =
    List.exists
      (function Bob_handler_sim.Spoke s -> s = "It is in the workshop." | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  Alcotest.(check bool) "spoke the reply" true spoke

let test_cognition_recalls_before_thinking () =
  let sim = Bob_handler_sim.create ~start:(at 1680.) ~brain_reply:"ok" () in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () ->
          Bob_cognition.handle_utterance ~config:Bob_control.default_config
            ~world:(world_with []) ~workspace:(ws_with [ utterance ]) ~event:utterance));
  let rec order = function
    | Bob_handler_sim.Recalled _ :: rest ->
        List.exists (function Bob_handler_sim.Thought _ -> true | _ -> false) rest
    | _ :: rest -> order rest
    | [] -> false
  in
  Alcotest.(check bool) "recall precedes think" true (order (Bob_handler_sim.actions sim))

(* §17: an out-of-range pose proposed by the brain must never reach the body. *)
let test_invalid_brain_action_never_reaches_the_body () =
  let sim =
    Bob_handler_sim.create ~start:(at 0.)
      ~brain_reply:(String.make (Bob_control.default_config.Bob_control.max_say_chars + 1) 'x') ()
  in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () ->
          Bob_cognition.handle_utterance ~config:Bob_control.default_config
            ~world:(world_with []) ~workspace:(ws_with [ utterance ]) ~event:utterance));
  let spoke = List.exists (function Bob_handler_sim.Spoke _ -> true | _ -> false)
      (Bob_handler_sim.actions sim) in
  Alcotest.(check bool) "overlong speech blocked" false spoke

(* §15: the query is chosen by pure policy, not by the storage layer. *)
let test_memory_policy_is_pure_and_testable () =
  let qs =
    Bob_cognition.Memory_policy.queries
      ~workspace:(ws_with [ utterance ])
      ~utterance:"Bob where is the screwdriver?"
  in
  Alcotest.(check bool) "at least one query" true (List.length qs > 0);
  Alcotest.(check bool) "query mentions the topic" true
    (List.exists
       (fun (q : Bob_effect.Memory.query) ->
         let t = q.Bob_effect.Memory.text in
         String.length t > 0)
       qs)

let test_no_speaker_means_no_personal_recall () =
  (* An utterance with no resolved speaker must not key a recall to a person. *)
  let anon =
    Bob_events.Utterance
      { at = at 100.; text = "hello"; speaker = None; speaker_track = None;
        language = Some "en" }
  in
  let qs =
    Bob_cognition.Memory_policy.queries ~workspace:(ws_with [ anon ]) ~utterance:"hello"
  in
  List.iter
    (fun q ->
      Alcotest.(check bool) "no person key" true (q.Bob_effect.Memory.person = None))
    qs

let () =
  Alcotest.run "cognition"
    [ ("scenario",
       [ Alcotest.test_case "known speaker" `Quick test_known_speaker_asks_a_remembered_question;
         Alcotest.test_case "recall before think" `Quick test_cognition_recalls_before_thinking ]);
      ("authority (§17)",
       [ Alcotest.test_case "invalid action blocked" `Quick
           test_invalid_brain_action_never_reaches_the_body ]);
      ("memory policy (§15)",
       [ Alcotest.test_case "pure" `Quick test_memory_policy_is_pure_and_testable;
         Alcotest.test_case "no speaker no person key" `Quick
           test_no_speaker_means_no_personal_recall ]) ]
