open Bob_types

let at ms = Time.of_ms ms

let recording =
  Bob_handler_replay.
    { times = [ at 0.; at 1680. ];
      recalls = [ [ Bob_domain.Memory.{ text = "workshop"; source = "profile" } ] ];
      thinks = [ "It is in the workshop." ];
      identities = [ Bob_domain.Identity.Matched (Person_id.v "gustaf", Confidence.v 0.9) ] }

let test_recorded_time_is_returned_in_order () =
  let r = Bob_handler_replay.create recording in
  let a, b =
    Bob_handler_replay.run r (fun () ->
        let a = Bob_effect.Clock.now () in
        let b = Bob_effect.Clock.now () in
        (a, b))
  in
  Alcotest.(check (float 0.001)) "first" 0. (Time.to_ms a);
  Alcotest.(check (float 0.001)) "second" 1680. (Time.to_ms b)

let test_recorded_think_is_replayed () =
  let r = Bob_handler_replay.create recording in
  let text =
    Bob_handler_replay.run r (fun () ->
        let s = Bob_effect.Brain.think
            Bob_domain.Brain.{ context = ""; utterance = ""; speaker = None } in
        let b = Buffer.create 64 in
        let rec d () =
          match Eio.Stream.take s with
          | Bob_domain.Brain.Text t ->
              if Buffer.length b > 0 then Buffer.add_char b ' ';
              Buffer.add_string b t; d ()
          | Bob_domain.Brain.Failed _ -> ()
        in
        d (); Buffer.contents b)
  in
  Alcotest.(check string) "replayed" "It is in the workshop." text

(* §8: no network, no hardware, no LLM. Exhausting the recording is an error,
   not a silent fallback to live behaviour. *)
let test_exhausted_recording_raises () =
  let r = Bob_handler_replay.create Bob_handler_replay.{ recording with thinks = [] } in
  let raised = ref false in
  (try
     ignore
       (Bob_handler_replay.run r (fun () ->
            Bob_effect.Brain.think
              Bob_domain.Brain.{ context = ""; utterance = ""; speaker = None }))
   with Bob_handler_replay.Exhausted _ -> raised := true);
  Alcotest.(check bool) "raised Exhausted" true !raised

let test_actions_are_asserted_against_expectations () =
  let r = Bob_handler_replay.create recording in
  Bob_handler_replay.run r (fun () ->
      ignore (Bob_effect.Body.look_at Bob_domain.Body.Neutral))
  |> ignore;
  match Bob_handler_replay.actions r with
  | [ Bob_handler_replay.Looked Bob_domain.Body.Neutral ] -> ()
  | l -> Alcotest.failf "expected one Looked, got %d" (List.length l)

let () =
  Alcotest.run "handler_replay"
    [ ("recorded",
       [ Alcotest.test_case "time in order" `Quick test_recorded_time_is_returned_in_order;
         Alcotest.test_case "think replayed" `Quick test_recorded_think_is_replayed;
         Alcotest.test_case "exhausted raises" `Quick test_exhausted_recording_raises;
         Alcotest.test_case "actions recorded" `Quick
           test_actions_are_asserted_against_expectations ]) ]
