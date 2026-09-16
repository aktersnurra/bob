open Bob_types

let at ms = Time.of_ms ms

let test_clock_is_deterministic_and_advances () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  let a, b =
    Bob_handler_sim.run sim (fun () ->
        let a = Bob_effect.Clock.now () in
        Bob_handler_sim.advance sim 250.;
        let b = Bob_effect.Clock.now () in
        (a, b))
  in
  Alcotest.(check (float 0.001)) "start" 0. (Time.to_ms a);
  Alcotest.(check (float 0.001)) "advanced" 250. (Time.to_ms b)

let test_recall_returns_configured_fixture () =
  let sim =
    Bob_handler_sim.create ~start:(at 0.)
      ~memory:[ Bob_effect.Memory.{ text = "likes dinosaurs"; source = "profile" } ]
      ()
  in
  let items =
    Bob_handler_sim.run sim (fun () ->
        Bob_effect.Memory.recall
          Bob_effect.Memory.{ text = "dinosaur"; person = Some (Person_id.v "olle") })
  in
  Alcotest.(check int) "one" 1 (List.length items);
  Alcotest.(check string) "text" "likes dinosaurs"
    (List.hd items).Bob_effect.Memory.text

let test_think_streams_the_configured_reply () =
  let sim = Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"It is on the desk." () in
  let text =
    Bob_handler_sim.run sim (fun () ->
        let s = Bob_effect.Brain.think
            Bob_effect.Brain.{ context = "CURRENT"; utterance = "where"; speaker = None } in
        Bob_handler_sim.drain_brain s)
  in
  Alcotest.(check string) "reply" "It is on the desk." text

(* §19 / C4: a configured failure arrives as a chunk, mid-stream. *)
let test_think_can_fail_midstream () =
  let sim =
    Bob_handler_sim.create ~start:(at 0.)
      ~brain_reply:"I think" ~brain_fails_after:1 ()
  in
  let got =
    Bob_handler_sim.run sim (fun () ->
        let s = Bob_effect.Brain.think
            Bob_effect.Brain.{ context = ""; utterance = ""; speaker = None } in
        let rec collect acc =
          match Eio.Stream.take s with
          | Bob_effect.Brain.Text t -> collect (acc ^ t)
          | Bob_effect.Brain.Failed e ->
              `Failed (acc, Bob_effect.Brain.error_to_string e)
        in
        collect "")
  in
  match got with
  | `Failed (_partial, name) -> Alcotest.(check string) "rate_limited" "rate_limited" name

let test_actions_are_recorded_in_order () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  Bob_handler_sim.run sim (fun () ->
      ignore (Bob_effect.Body.look_at (Bob_effect.Body.Bearing (Angle.deg (-31.))));
      ignore (Bob_effect.Body.look_at Bob_effect.Body.Neutral))
  |> ignore;
  match Bob_handler_sim.actions sim with
  | [ Bob_handler_sim.Looked (Bob_effect.Body.Bearing a);
      Bob_handler_sim.Looked Bob_effect.Body.Neutral ] ->
      Alcotest.(check (float 0.1)) "bearing" (-31.) (Angle.to_deg a)
  | l -> Alcotest.failf "unexpected actions: %d" (List.length l)

let test_speak_records_chunks_incrementally () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  Bob_handler_sim.run sim (fun () ->
      (* Fill then perform: spawning a fiber here would break the handler
         chain (C1). Capacity 8 > 3 items, so no add blocks. *)
      let s = Eio.Stream.create 8 in
      Eio.Stream.add s (Bob_effect.Speech.Say "Hej");
      Eio.Stream.add s (Bob_effect.Speech.Say " Bob");
      Eio.Stream.add s Bob_effect.Speech.End;
      ignore (Bob_effect.Speech.say s))
  |> ignore;
  match Bob_handler_sim.actions sim with
  | [ Bob_handler_sim.Spoke text ] ->
      Alcotest.(check string) "joined" "Hej Bob" text
  | l -> Alcotest.failf "expected one Spoke, got %d" (List.length l)

let test_identify_returns_configured_identity () =
  let sim =
    Bob_handler_sim.create ~start:(at 0.)
      ~identity:(Bob_effect.Identity.Matched (Person_id.v "gustaf", Confidence.v 0.93)) ()
  in
  let r =
    Bob_handler_sim.run sim (fun () ->
        Bob_effect.Identity.identify Bob_effect.Identity.{ track = Track_id.v 7 })
  in
  match r with
  | Bob_effect.Identity.Matched (p, _) ->
      Alcotest.(check string) "gustaf" "gustaf" (Person_id.to_string p)
  | _ -> Alcotest.fail "expected a match"

let () =
  Alcotest.run "handler_sim"
    [ ("clock", [ Alcotest.test_case "deterministic" `Quick test_clock_is_deterministic_and_advances ]);
      ("memory", [ Alcotest.test_case "fixture" `Quick test_recall_returns_configured_fixture ]);
      ("brain",
       [ Alcotest.test_case "streams reply" `Quick test_think_streams_the_configured_reply;
         Alcotest.test_case "fails midstream" `Quick test_think_can_fail_midstream ]);
      ("actions",
       [ Alcotest.test_case "ordered" `Quick test_actions_are_recorded_in_order;
         Alcotest.test_case "speech chunks" `Quick test_speak_records_chunks_incrementally ]);
      ("identity", [ Alcotest.test_case "configured" `Quick test_identify_returns_configured_identity ]) ]
