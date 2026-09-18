open Bob_types

let at ms = Time.of_ms ms

(* C1: this is the test that would have caught the patch's central error. *)
let test_effects_work_inside_a_forked_fiber () =
  let sim = Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"ok" () in
  let out = ref (Time.of_ms (-1.)) in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () -> out := Bob_effect.Clock.now ()));
  Alcotest.(check (float 0.001)) "fiber saw the clock" 0. (Time.to_ms !out)

let test_two_fibers_each_get_handlers () =
  let sim = Bob_handler_sim.create ~start:(at 5.) () in
  let a = ref (Time.of_ms (-1.)) and b = ref (Time.of_ms (-1.)) in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () -> a := Bob_effect.Clock.now ());
      Bob_runtime.fork ~sw ~sim (fun () -> b := Bob_effect.Clock.now ()));
  Alcotest.(check (float 0.001)) "fiber a" 5. (Time.to_ms !a);
  Alcotest.(check (float 0.001)) "fiber b" 5. (Time.to_ms !b)

(* A bare Eio.Fiber.fork inside cognition is a BUG. Prove it fails loudly,
   so nobody "simplifies" Bob_runtime.fork away later. *)
let test_bare_fork_is_unhandled () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  let raised = ref false in
  (try
     Bob_runtime.run_sim sim (fun sw ->
         Eio.Fiber.fork ~sw (fun () -> ignore (Bob_effect.Clock.now ())))
   with Effect.Unhandled _ -> raised := true);
  Alcotest.(check bool) "bare fork is unhandled" true !raised

(* C5: the trace must actually capture. The wrong nesting is silent. *)
let test_tracing_captures_effects () =
  let sim = Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"hi" () in
  let tr = Bob_runtime.new_trace () in
  Bob_runtime.run_sim ~trace:tr sim (fun _sw ->
      ignore (Bob_effect.Clock.now ());
      ignore (Bob_effect.Body.look_at Bob_domain.Body.Neutral));
  let names = Bob_runtime.trace_names tr in
  Alcotest.(check bool) "captured Now" true (List.mem "Now" names);
  Alcotest.(check bool) "captured Look_at" true (List.mem "Look_at" names)

let test_trace_is_not_silently_empty () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  let tr = Bob_runtime.new_trace () in
  Bob_runtime.run_sim ~trace:tr sim (fun _sw -> ignore (Bob_effect.Clock.now ()));
  Alcotest.(check bool) "non-empty" true (List.length (Bob_runtime.trace_names tr) > 0)

let test_trace_records_durations () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  let tr = Bob_runtime.new_trace () in
  Bob_runtime.run_sim ~trace:tr sim (fun _sw -> ignore (Bob_effect.Clock.now ()));
  List.iter
    (fun (_, ms) ->
      Alcotest.(check bool) "non-negative duration" true (ms >= 0.))
    (Bob_runtime.trace_entries tr)

(* §20 forbids logging raw prompts. The trace stores names and timings only. *)
let test_trace_does_not_record_prompt_text () =
  let sim = Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"secret answer" () in
  let tr = Bob_runtime.new_trace () in
  Bob_runtime.run_sim ~trace:tr sim (fun sw ->
      Bob_runtime.fork ~sw ~sim ~trace:tr (fun () ->
          let s = Bob_effect.Brain.think
              Bob_domain.Brain.{ context = "SECRET CONTEXT"; utterance = "secret question";
                                 speaker = None } in
          ignore (Bob_handler_sim.drain_brain s)));
  let dumped = String.concat " " (Bob_runtime.trace_names tr) in
  let contains h n =
    let nl = String.length n and hl = String.length h in
    let rec go i = i + nl <= hl && (String.sub h i nl = n || go (i + 1)) in
    nl = 0 || go 0
  in
  Alcotest.(check bool) "no prompt text" false (contains dumped "SECRET");
  Alcotest.(check bool) "no question text" false (contains dumped "secret question")

let () =
  Alcotest.run "runtime"
    [ ("fibers (C1)",
       [ Alcotest.test_case "effects inside fork" `Quick test_effects_work_inside_a_forked_fiber;
         Alcotest.test_case "two fibers" `Quick test_two_fibers_each_get_handlers;
         Alcotest.test_case "bare fork unhandled" `Quick test_bare_fork_is_unhandled ]);
      ("tracing (C5)",
       [ Alcotest.test_case "captures" `Quick test_tracing_captures_effects;
         Alcotest.test_case "not silently empty" `Quick test_trace_is_not_silently_empty;
         Alcotest.test_case "durations" `Quick test_trace_records_durations;
         Alcotest.test_case "no prompt text" `Quick test_trace_does_not_record_prompt_text ]) ]
