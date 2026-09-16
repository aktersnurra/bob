open Bob_types

let at ms = Time.of_ms ms

(* §13: a slow Think must be cancellable by a surrounding timeout. *)
let test_timeout_cancels_a_slow_think () =
  let sim =
    Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"one two three four five"
      ~chunk_delay:0.05 ()
  in
  let cancelled = ref false in
  Bob_handler_sim.run_with_clock sim (fun clock ->
      try
        Eio.Time.with_timeout_exn clock 0.08 (fun () ->
            let s = Bob_effect.Brain.think
                Bob_effect.Brain.{ context = ""; utterance = ""; speaker = None } in
            ignore (Bob_handler_sim.drain_brain s))
      with Eio.Time.Timeout -> cancelled := true);
  Alcotest.(check bool) "cancelled" true !cancelled

(* Barge-in: cancelling speech must stop it partway, not after completion. *)
let test_barge_in_stops_speech_partway () =
  let sim = Bob_handler_sim.create ~start:(at 0.) ~chunk_delay:0.05 () in
  Bob_handler_sim.run_with_clock sim (fun clock ->
      try
        Eio.Time.with_timeout_exn clock 0.08 (fun () ->
            let s = Eio.Stream.create 16 in
            List.iter (fun w -> Eio.Stream.add s (Bob_effect.Speech.Say w))
              [ "one"; "two"; "three"; "four"; "five" ];
            Eio.Stream.add s Bob_effect.Speech.End;
            ignore (Bob_effect.Speech.say s))
      with Eio.Time.Timeout -> ());
  (* Whatever was spoken must be shorter than the whole utterance. *)
  let spoken =
    List.filter_map (function Bob_handler_sim.Spoke s -> Some s | _ -> None)
      (Bob_handler_sim.actions sim)
  in
  List.iter
    (fun s ->
      Alcotest.(check bool) "partial, not complete" true
        (String.length s < String.length "onetwothreefourfive"))
    spoken

let test_cancellation_does_not_corrupt_later_effects () =
  let sim = Bob_handler_sim.create ~start:(at 0.) ~chunk_delay:0.05 () in
  let after = ref (Time.of_ms (-1.)) in
  Bob_handler_sim.run_with_clock sim (fun clock ->
      (try
         Eio.Time.with_timeout_exn clock 0.02 (fun () ->
             Eio.Time.sleep clock 1.0)
       with Eio.Time.Timeout -> ());
      after := Bob_effect.Clock.now ());
  Alcotest.(check (float 0.001)) "clock still works" 0. (Time.to_ms !after)

let () =
  Alcotest.run "cancellation"
    [ ("§13",
       [ Alcotest.test_case "timeout cancels think" `Quick test_timeout_cancels_a_slow_think;
         Alcotest.test_case "barge-in stops speech" `Quick test_barge_in_stops_speech_partway;
         Alcotest.test_case "no corruption after" `Quick
           test_cancellation_does_not_corrupt_later_effects ]) ]
