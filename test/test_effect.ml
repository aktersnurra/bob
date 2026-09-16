open Bob_types
open Effect.Deep

(* A minimal handler, written here rather than imported, so this test proves
   the vocabulary is usable on its own. *)
let with_stub f =
  Effect.Deep.match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Bob_effect.Now ->
              Some (fun (k : (a, _) continuation) -> continue k (Time.of_ms 42.))
          | Bob_effect.Recall _ ->
              Some (fun k -> continue k [ Bob_effect.Memory.{ text = "likes dinosaurs"; source = "profile" } ])
          | Bob_effect.Look_at _ -> Some (fun k -> continue k (Ok ()))
          | _ -> None) }

let test_now_goes_through_the_wrapper () =
  let t = with_stub (fun () -> Bob_effect.Clock.now ()) in
  Alcotest.(check (float 0.001)) "42" 42. (Time.to_ms t)

let test_recall_returns_items () =
  let items =
    with_stub (fun () -> Bob_effect.Memory.recall Bob_effect.Memory.{ text = "screwdriver"; person = Some (Person_id.v "gustaf") })
  in
  Alcotest.(check int) "one item" 1 (List.length items)

let test_look_at_returns_ok () =
  match with_stub (fun () -> Bob_effect.Body.look_at (Bob_effect.Body.Bearing (Angle.deg (-31.)))) with
  | Ok () -> ()
  | Error _ -> Alcotest.fail "expected Ok"

(* C4: a brain failure is a chunk INSIDE the stream, not a wrapper around it,
   because a stream already returned cannot fail with a result-typed error. *)
let test_brain_failure_is_a_chunk () =
  let c = Bob_effect.Brain.Failed Bob_effect.Brain.Rate_limited in
  match c with
  | Bob_effect.Brain.Failed Bob_effect.Brain.Rate_limited -> ()
  | _ -> Alcotest.fail "expected a Failed chunk"

let test_error_names_are_total () =
  List.iter
    (fun e ->
      Alcotest.(check bool) "non-empty name" true
        (String.length (Bob_effect.Brain.error_to_string e) > 0))
    [ Bob_effect.Brain.Timeout; Bob_effect.Brain.Unavailable;
      Bob_effect.Brain.Rate_limited; Bob_effect.Brain.Invalid_response ]

(* §6: cognition must never see Effect.perform. The wrappers are the API. *)
let test_wrappers_exist_for_every_effect () =
  (* This is a compile-time assertion: if a wrapper is missing or renamed,
     this will not build. *)
  let _ = Bob_effect.Clock.now in
  let _ = Bob_effect.Memory.recall in
  let _ = Bob_effect.Brain.think in
  let _ = Bob_effect.Speech.say in
  let _ = Bob_effect.Body.look_at in
  let _ = Bob_effect.Identity.identify in
  ()

let () =
  Alcotest.run "effect"
    [ ("wrappers",
       [ Alcotest.test_case "now" `Quick test_now_goes_through_the_wrapper;
         Alcotest.test_case "recall" `Quick test_recall_returns_items;
         Alcotest.test_case "look_at" `Quick test_look_at_returns_ok;
         Alcotest.test_case "all present" `Quick test_wrappers_exist_for_every_effect ]);
      ("errors",
       [ Alcotest.test_case "failure is a chunk" `Quick test_brain_failure_is_a_chunk;
         Alcotest.test_case "names total" `Quick test_error_names_are_total ]) ]
