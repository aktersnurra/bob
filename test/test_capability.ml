(* The capability layer's job is to make authority checkable. These tests
   check the POSITIVE case: that a granted capability works and reaches the
   handler. The NEGATIVE case - that a denied capability cannot even be named
   - is a compile-fail test, in test/deny/, because a module that fails to
   compile cannot also be an alcotest case. *)

open Bob_types

let at ms = Time.of_ms ms

(* A conversation-only subsystem: it may speak, but it has no way to move
   Bob, because CONVERSATION_CAPABILITIES has no look_at. *)
module Chatty (C : Bob_capability.CONVERSATION_CAPABILITIES) = struct
  let run () =
    let _now = C.now () in
    let items =
      C.recall Bob_domain.Memory.{ text = "dinosaur"; person = None }
    in
    let s =
      C.think
        Bob_domain.Brain.{ context = ""; utterance = "hej"; speaker = None }
    in
    let buf = Buffer.create 32 in
    let rec drain () =
      match Eio.Stream.take s with
      | Bob_domain.Brain.Text t ->
          if Buffer.length buf > 0 then Buffer.add_char buf ' ';
          Buffer.add_string buf t;
          drain ()
      | Bob_domain.Brain.Failed _ -> ()
    in
    drain ();
    let out = Eio.Stream.create 4 in
    Eio.Stream.add out (Bob_domain.Speech.Say (Buffer.contents buf));
    Eio.Stream.add out Bob_domain.Speech.End;
    ignore (C.speak out);
    List.length items
end

module Chatty_live = Chatty (Bob_capability.Conversation)

(* An embodied subsystem may do everything the conversational one may, plus
   move. EMBODIED includes CONVERSATION, so this instantiation type-checks. *)
module Chatty_embodied = Chatty (Bob_capability.Embodied)

let test_granted_conversation_reaches_the_handler () =
  let sim =
    Bob_handler_sim.create ~start:(at 0.)
      ~memory:[ Bob_domain.Memory.{ text = "likes dinosaurs"; source = "profile" } ]
      ~brain_reply:"Hej Bob" ()
  in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () -> ignore (Chatty_live.run ())));
  let spoke =
    List.exists
      (function Bob_handler_sim.Spoke s -> s = "Hej Bob" | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  Alcotest.(check bool) "spoke through the capability" true spoke

let test_conversation_capability_moves_nothing () =
  (* Denial is enforced at compile time, but assert the runtime consequence
     too: a conversation-only subsystem emits no body action. *)
  let sim = Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"hej" () in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () -> ignore (Chatty_live.run ())));
  let looked =
    List.exists
      (function Bob_handler_sim.Looked _ -> true | _ -> false)
      (Bob_handler_sim.actions sim)
  in
  Alcotest.(check bool) "no body action" false looked

let test_embodied_can_move () =
  let sim = Bob_handler_sim.create ~start:(at 0.) () in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () ->
          ignore (Bob_capability.Embodied.look_at Bob_domain.Body.Neutral)));
  match Bob_handler_sim.actions sim with
  | [ Bob_handler_sim.Looked Bob_domain.Body.Neutral ] -> ()
  | l -> Alcotest.failf "expected one Looked, got %d" (List.length l)

let test_embodied_satisfies_conversation () =
  (* A compile-time assertion: if EMBODIED stopped including CONVERSATION,
     this module would not build. *)
  let sim = Bob_handler_sim.create ~start:(at 0.) ~brain_reply:"ok" () in
  Bob_runtime.run_sim sim (fun sw ->
      Bob_runtime.fork ~sw ~sim (fun () -> ignore (Chatty_embodied.run ())));
  Alcotest.(check bool) "instantiated" true true

let () =
  Alcotest.run "capability"
    [ ("granted",
       [ Alcotest.test_case "conversation reaches handler" `Quick
           test_granted_conversation_reaches_the_handler;
         Alcotest.test_case "embodied can move" `Quick test_embodied_can_move;
         Alcotest.test_case "embodied satisfies conversation" `Quick
           test_embodied_satisfies_conversation ]);
      ("denied",
       [ Alcotest.test_case "conversation moves nothing" `Quick
           test_conversation_capability_moves_nothing ]) ]
