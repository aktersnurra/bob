# Bob Patch 002 — Effect-Handled Cognitive Runtime: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Bob's capability function-records with OCaml 5 domain effects and three handler environments (sim, replay, live), add streaming brain/speech and Eio cancellation, without touching the pure reducers.

**Architecture:** Pure reducers (`World.apply`, `Workspace.apply`, `Control.decide`) keep their explicit `~now` parameters and stay untouched. Cognition performs a small semantic effect vocabulary — `Now`, `Recall`, `Think`, `Speak`, `Look_at`, `Identify` — through typed wrapper functions, never raw `Effect.perform`. Handlers interpret those effects: sim (deterministic), replay (recorded), live (OpenRouter/SQLite/OpenRB). Capability *records* survive as the authority mechanism per §5, because OCaml effects are not statically tracked.

**Tech Stack:** OCaml 5.4.1 (stock `default` switch, **not** `5.2.0+ox`), dune 3.24, `eio_main` 1.5, existing Phase 0 libraries, `alcotest` + `qcheck-alcotest`.

**Read first:** `docs/patches/002-effect-handled-runtime-CORRECTIONS.md`. It records seven defects in the patch as written, each verified by running the case. Three are load-bearing for this plan:

- **C1** Effect handlers do not cross **any** fiber spawn — `fork`, `both` and `first` all break the chain. Every fiber installs its own stack; prefer fill-then-perform for local streams.
- **C4** A returned stream cannot fail with a result-typed error; the error is a `Failed` chunk *inside* the stream.
- **C5** Tracing nests **inside** the interpreting handler, not outside. The wrong order fails silently.

---

## Prerequisites

Already done — do not redo:

- Phase 0 complete: 101 tests, 12 suites, clean build.
- Libraries: `bob_types`, `bob_events`, `bob_world`, `bob_workspace`, `bob_control`, `bob_memory`, `bob_project`, `bob_capability`, `bob_obs`, `bob_trace`.
- `eio_main` 1.5 installed on the `default` switch.

**Switch discipline.** The opam switch is directory-local. In any fresh working directory run once:

```bash
opam switch link default
opam switch show                 # must print: default
opam exec -- ocamlopt -version   # must print: 5.4.1
```

All commands run from the workspace root. **Commit with `jj commit -m "..."`, never `git commit`.**

---

## Verified before writing this plan

Compiled and run on this machine, not reasoned about:

| Claim | Result |
|---|---|
| Handler outside, `perform` in forked fiber | **`Effect.Unhandled`** |
| Handler installed inside each fiber | works |
| `Fiber.both` / `Fiber.first` with handler outside | **`Effect.Unhandled`** (same as fork) |
| `Fiber.yield` under a handler | works (spawns no fiber) |
| Spawn helper `bob_fork ~sw f = Eio.Fiber.fork ~sw (fun () -> with_handlers f)` | works, two concurrent fibers |
| Fill a stream then perform (no fiber spawned) | works |
| The `Memory`-then-`include Memory` wrapper re-export pattern | **WRONG — see below** |
| `handle t ?clock sw f` — optional before positional, forwarded twice | works |
| Eio timeout around a blocking effect | cancels correctly |
| Handler body performs Eio IO while servicing | works |
| Streaming: handler forks producer, returns `Eio.Stream.t` | first chunk at 10 ms of a 60 ms generation |
| Mid-stream typed failure as a `Failed` chunk | `"I think it's" then FAILED(rate_limited)` |
| `with_sim (with_tracing f)` | trace captured |
| `with_tracing (with_sim f)` | **captures nothing, does not error** |

**Correction to the table above (found during Task 1).** The re-export row was
wrong. A module cannot be redefined by `include`-ing itself under the same name
in one structure — OCaml rejects it with *"Multiple definition of the module
name"*. Re-verified with plain `ocamlopt` outside dune, so it is not a build
artifact.

The working form stages the types under a private name and exposes the public
module once:

```ocaml
module Memory0 = struct type item = { text : string; source : string } end
(* ... effect declarations referencing Memory0 ... *)
module Memory = struct include Memory0 let recall = Memory_op.recall end
```

`Memory0` is file-private staging; the public surface
(`Bob_effect.Memory.recall` and the types) is unchanged.

Effect declaration syntax that compiles:

```ocaml
type _ Effect.t += Now : Time.t Effect.t
type _ Effect.t += Recall : Memory.query -> Memory.item list Effect.t
```

One `+=` per constructor, GADT return type on the constructor.

---

## File Structure

Patch §24 suggests `lib/effects/` and `lib/handlers/{live,sim,replay}/`. Phase 0 uses one library per directory with a single module matching the library name — and a library whose `(name X)` matches a module `X.ml` hides sibling modules. So each of §24's groups becomes one library with submodules inside a single file, which preserves §24's conceptual separation without fighting the build.

```
lib/
  effect/       bob_effect       The effect declarations + typed wrapper
                                 functions (Clock, Memory, Brain, Speech,
                                 Body, Identity submodules). The ONLY place
                                 Effect.perform appears.
                                 Deps: types, control, memory.
  handler_sim/  bob_handler_sim  Deterministic handlers + the recording
                                 needed to assert on what cognition did.
                                 Deps: effect, types, control.
  handler_replay/ bob_handler_replay
                                 Recorded-result handlers; asserts actions
                                 against expectations.
                                 Deps: effect, types, control.
  handler_live/ bob_handler_live OpenRouter brain, SQLite memory, OpenRB
                                 body. COMPILES but cannot be run here.
                                 Deps: effect, memory, eio_main, cohttp-eio.
  runtime/      bob_runtime      The per-fiber spawn helper (C1), handler
                                 stack composition, and the tracing handler
                                 (C5). Deps: effect, obs, eio_main.
  cognition/    bob_cognition    The effectful cognitive flow: decision ->
                                 recall -> project -> think -> validate ->
                                 act. Deps: everything above.
```

`lib/capability/bob_capability.ml` **stays**. Patch §5 keeps capability modules as the authority mechanism; §11 requires that a subsystem denied a capability cannot use it, and effects alone cannot express that. The records become thin wrappers that perform effects.

**Unchanged:** `lib/types`, `lib/events`, `lib/world`, `lib/workspace`, `lib/control`, `lib/project`, `lib/memory`, `lib/obs`. Patch §2 and §26 require the reducers keep explicit inputs; C7 warns against converting their `~now` parameters to a `Now` effect.

---

### Task 1: The effect vocabulary and typed wrappers

Patch §3 (small semantic vocabulary), §6 (no unrestricted global `perform`),
§19 (typed domain errors), §10/§11 (streaming), and correction C3 (declaration
syntax) and C4 (error-in-stream).

Six effects, no more. §25 forbids a framework.

**Files:**
- Create: `lib/effect/dune`, `lib/effect/bob_effect.ml`, `test/test_effect.ml`
- Modify: `test/dune`

- [ ] **Step 1: Write the failing test**

Update `test/dune` — keep every existing name, add `test_effect`, add
`bob_effect` and `eio_main` to libraries:

```
(tests
 (names test_types test_events test_world test_workspace test_control test_audit
   test_memory test_project test_audit_memory test_obs test_trace test_invariants
   test_effect)
 (libraries bob_types bob_events bob_world bob_workspace bob_control bob_trace
   bob_capability bob_memory bob_project bob_obs bob_effect eio_main alcotest
   qcheck-core qcheck-alcotest yojson unix)
 (deps (glob_files fixtures/*.trace)))
```

Create `test/test_effect.ml`:

```ocaml
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `Library "bob_effect" not found.`

- [ ] **Step 3: Implement the vocabulary**

Create `lib/effect/dune`:

```
(library
 (name bob_effect)
 (libraries bob_types bob_control eio))
```

Create `lib/effect/bob_effect.ml`:

```ocaml
open Bob_types

(* Patch 002 §3: a small semantic vocabulary. Six effects. §25 forbids
   growing this into a framework.

   §6: Effect.perform appears ONLY in this file. Everything else calls the
   typed wrappers below. *)

module Memory = struct
  type query = { text : string; person : Person_id.t option }
  type item = { text : string; source : string }

  type error = Unavailable | Corrupt of string

  let error_to_string = function
    | Unavailable -> "memory unavailable"
    | Corrupt m -> "memory corrupt: " ^ m
end

module Brain = struct
  type request = {
    context : string;
    utterance : string;
    speaker : Person_id.t option;
  }

  type error = Timeout | Unavailable | Rate_limited | Invalid_response

  let error_to_string = function
    | Timeout -> "timeout"
    | Unavailable -> "unavailable"
    | Rate_limited -> "rate_limited"
    | Invalid_response -> "invalid_response"

  (* C4: §10 wants a stream, §19 wants typed errors. A stream that has already
     been returned cannot fail with a result-typed error, because the failure
     happens after Think returned. So the error travels IN the stream.
     Consumers must handle Failed at any position, including first. *)
  type chunk = Text of string | Failed of error

  type response = chunk Eio.Stream.t
end

module Speech = struct
  (* §11: speech is incremental. The handler consumes chunks as they arrive
     rather than waiting for a complete utterance. *)
  type chunk = Say of string | End
  type stream = chunk Eio.Stream.t
  type error = Device_unavailable | Interrupted

  let error_to_string = function
    | Device_unavailable -> "speech device unavailable"
    | Interrupted -> "interrupted"
end

module Body = struct
  (* §3: semantic, not mechanical. Look_at a target, never Set_servo_pwm. *)
  type target =
    | Bearing of Angle.t
    | Person of Person_id.t
    | Track of Track_id.t
    | Neutral

  type error = Unreachable | Rejected of string | Disconnected

  let error_to_string = function
    | Unreachable -> "target unreachable"
    | Rejected m -> "rejected: " ^ m
    | Disconnected -> "body disconnected"
end

module Identity = struct
  type request = { track : Track_id.t }

  type result =
    | Matched of Person_id.t * Confidence.t
    | Unknown
    | Uncertain of (Person_id.t * Confidence.t) list

  type error = Worker_unavailable | No_face
end

(* --- The effects. C3: one += per constructor, GADT return on each. --- *)

type _ Effect.t += Now : Time.t Effect.t
type _ Effect.t += Recall : Memory.query -> Memory.item list Effect.t
type _ Effect.t += Think : Brain.request -> Brain.response Effect.t
type _ Effect.t += Speak : Speech.stream -> (unit, Speech.error) result Effect.t
type _ Effect.t += Look_at : Body.target -> (unit, Body.error) result Effect.t
type _ Effect.t += Identify : Identity.request -> Identity.result Effect.t

(* --- §6: typed wrappers. The rest of Bob calls these, never perform. --- *)

module Clock = struct
  let now () = Effect.perform Now
end

module Memory_op = struct
  let recall q = Effect.perform (Recall q)
end

module Brain_op = struct
  let think r = Effect.perform (Think r)
end

module Speech_op = struct
  let say s = Effect.perform (Speak s)
end

module Body_op = struct
  let look_at t = Effect.perform (Look_at t)
end

module Identity_op = struct
  let identify r = Effect.perform (Identify r)
end

(* Re-export the wrappers onto the type modules so call sites read as
   Bob_effect.Memory.recall rather than Bob_effect.Memory_op.recall. *)
module Memory = struct
  include Memory

  let recall = Memory_op.recall
end

module Brain = struct
  include Brain

  let think = Brain_op.think
end

module Speech = struct
  include Speech

  let say = Speech_op.say
end

module Body = struct
  include Body

  let look_at = Body_op.look_at
end

module Identity = struct
  include Identity

  let identify = Identity_op.identify
end

(* A human-readable name per effect, for the tracing handler (§20). *)
let name_of : type a. a Effect.t -> string option = function
  | Now -> Some "Now"
  | Recall _ -> Some "Recall"
  | Think _ -> Some "Think"
  | Speak _ -> Some "Speak"
  | Look_at _ -> Some "Look_at"
  | Identify _ -> Some "Identify"
  | _ -> None
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `effect` suite green, 6 tests; all 12 prior suites still green.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: domain effect vocabulary and typed wrappers

Six semantic effects per patch 002 section 3. Effect.perform appears only in
bob_effect.ml; everything else calls the typed wrappers, per section 6.

Brain failures travel as a Failed chunk inside the response stream rather
than a result wrapper around it (correction C4): a stream that has already
been returned cannot fail with a result-typed error, and mid-stream provider
failures are the common case.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Simulation handlers

Patch §7 (simulation environment) and §21 (scenario tests without hardware).

The sim handler is deterministic and records everything cognition did, so
tests can assert on actions rather than on internal state.

**Files:**
- Create: `lib/handler_sim/dune`, `lib/handler_sim/bob_handler_sim.ml`, `test/test_handler_sim.ml`
- Modify: `test/dune`

- [ ] **Step 1: Write the failing test**

Add `test_handler_sim` to the names in `test/dune` and `bob_handler_sim` to
libraries.

Create `test/test_handler_sim.ml`:

```ocaml
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `Library "bob_handler_sim" not found.`

- [ ] **Step 3: Implement the sim handlers**

Create `lib/handler_sim/dune`:

```
(library
 (name bob_handler_sim)
 (libraries bob_types bob_effect eio eio_main))
```

Create `lib/handler_sim/bob_handler_sim.ml`:

```ocaml
open Bob_types
open Effect.Deep

(* Patch 002 §7 simulation environment: deterministic, records what cognition
   did so scenario tests (§21) assert on actions rather than internals. *)

type action =
  | Looked of Bob_effect.Body.target
  | Spoke of string
  | Recalled of string
  | Thought of string
  | Identified of Track_id.t

type t = {
  mutable now : Time.t;
  mutable actions : action list; (* reverse order *)
  memory : Bob_effect.Memory.item list;
  brain_reply : string;
  brain_fails_after : int option;
  identity : Bob_effect.Identity.result;
  (* Seconds to pause between chunks. 0 means never sleep, so the common
     tests stay fast. Task 8 uses a non-zero value to exercise cancellation;
     the field exists from the start so `handle`'s signature never changes. *)
  chunk_delay : float;
}

let create ~start ?(memory = []) ?(brain_reply = "Jag vet inte.")
    ?brain_fails_after ?(identity = Bob_effect.Identity.Unknown)
    ?(chunk_delay = 0.) () =
  { now = start; actions = []; memory; brain_reply; brain_fails_after; identity;
    chunk_delay }

let advance t ms = t.now <- Time.add t.now ms
let actions t = List.rev t.actions
let record t a = t.actions <- a :: t.actions

(* Split a reply into word chunks so streaming is exercised rather than
   simulated as one blob. *)
let words s = String.split_on_char ' ' s |> List.filter (fun w -> w <> "")

let drain_brain (s : Bob_effect.Brain.response) =
  let rec go acc =
    match Eio.Stream.take s with
    | Bob_effect.Brain.Text t -> go (if acc = "" then t else acc ^ " " ^ t)
    | Bob_effect.Brain.Failed _ -> acc
  in
  go ""

(* The handler. It needs a switch to fork producer fibers for streaming brain
   responses, so `run` takes one from Eio_main.

   `?clock` is optional and unused while chunk_delay is 0. It is present from
   the start so Task 8 can add pacing without changing this signature. *)
let pace t clock =
  if t.chunk_delay > 0. then
    match clock with Some c -> Eio.Time.sleep c t.chunk_delay | None -> ()

let handle t ?clock sw f =
  match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Bob_effect.Now ->
              Some (fun (k : (a, _) continuation) -> continue k t.now)
          | Bob_effect.Recall q ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Recalled q.Bob_effect.Memory.text);
                  continue k t.memory)
          | Bob_effect.Think r ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Thought r.Bob_effect.Brain.utterance);
                  let stream = Eio.Stream.create 16 in
                  (* §10: produce concurrently so the consumer may start
                     before generation finishes. *)
                  Eio.Fiber.fork ~sw (fun () ->
                      let ws = words t.brain_reply in
                      List.iteri
                        (fun i w ->
                          pace t clock;
                          match t.brain_fails_after with
                          | Some n when i >= n ->
                              if i = n then
                                Eio.Stream.add stream
                                  (Bob_effect.Brain.Failed
                                     Bob_effect.Brain.Rate_limited)
                          | _ -> Eio.Stream.add stream (Bob_effect.Brain.Text w))
                        ws;
                      match t.brain_fails_after with
                      | Some n when n < List.length ws -> ()
                      | _ ->
                          Eio.Stream.add stream
                            (Bob_effect.Brain.Failed Bob_effect.Brain.Invalid_response));
                  continue k stream)
          | Bob_effect.Speak stream ->
              Some
                (fun (k : (a, _) continuation) ->
                  (* Record incrementally, not only at the end: a speech
                     cancelled partway must leave evidence of what was
                     actually said, or Task 8 cannot tell partial from
                     absent. *)
                  let buf = Buffer.create 64 in
                  let commit () =
                    t.actions <-
                      (match t.actions with
                      | Spoke _ :: rest -> Spoke (Buffer.contents buf) :: rest
                      | l -> Spoke (Buffer.contents buf) :: l)
                  in
                  let rec drain () =
                    match Eio.Stream.take stream with
                    | Bob_effect.Speech.End -> ()
                    | Bob_effect.Speech.Say s ->
                        pace t clock;
                        Buffer.add_string buf s;
                        commit ();
                        drain ()
                  in
                  drain ();
                  commit ();
                  continue k (Ok ()))
          | Bob_effect.Look_at target ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Looked target);
                  continue k (Ok ()))
          | Bob_effect.Identify r ->
              Some
                (fun (k : (a, _) continuation) ->
                  record t (Identified r.Bob_effect.Identity.track);
                  continue k t.identity)
          | _ -> None) }

(* Convenience: run a cognitive function under the sim environment, supplying
   its own Eio runtime. Tests call this. *)
let run t f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw -> handle t ~clock sw f

(* Like run, but hands the callback the clock so tests can impose timeouts
   (Task 8 uses this for cancellation). *)
let run_with_clock t f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw -> handle t ~clock sw (fun () -> f clock)
```

Note: the brain stream ends with an `Invalid_response` chunk rather than a
sentinel, because `Brain.chunk` has no explicit terminator — `drain_brain`
stops at the first non-`Text`. If a terminator proves clearer during
implementation, add `Brain.Done` and report it.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `handler_sim` suite green, 7 tests.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: simulation effect handlers

Deterministic handlers that record what cognition did, so scenario tests
assert on actions rather than internal state (patch 002 sections 7 and 21).
The brain handler forks a producer fiber and streams word chunks, exercising
section 10's incremental output rather than returning a blob.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: Runtime — per-fiber spawn helper and tracing handler

This task exists because of corrections **C1** and **C5**, which are the two
places the patch as written does not work.

- **C1**: effect handlers do not cross `Eio.Fiber.fork`. Patch §12's eight
  concurrent loops cannot share one outer handler. Every fiber installs its
  own stack, so all forking goes through one helper.
- **C5**: the tracing handler (§20) must nest **inside** the interpreting
  handler. `with_sim (with_tracing f)` captures; `with_tracing (with_sim f)`
  captures nothing **and does not error**.

**Files:**
- Create: `lib/runtime/dune`, `lib/runtime/bob_runtime.ml`, `test/test_runtime.ml`
- Modify: `test/dune`

- [ ] **Step 1: Write the failing test**

Add `test_runtime` to names, `bob_runtime` to libraries.

Create `test/test_runtime.ml`:

```ocaml
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
      ignore (Bob_effect.Body.look_at Bob_effect.Body.Neutral));
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
              Bob_effect.Brain.{ context = "SECRET CONTEXT"; utterance = "secret question";
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `Library "bob_runtime" not found.`

- [ ] **Step 3: Implement the runtime**

Create `lib/runtime/dune`:

```
(library
 (name bob_runtime)
 (libraries bob_types bob_effect bob_handler_sim eio eio_main unix))
```

Create `lib/runtime/bob_runtime.ml`:

```ocaml
open Effect.Deep

(* Patch 002 §12 + correction C1.

   Effect handlers do NOT cross Eio.Fiber.fork: a perform inside a forked
   fiber raises Effect.Unhandled, because Eio fibers are themselves built on
   effects and forking installs Eio's own handler.

   Therefore every fiber must install its own handler stack. All forking in
   cognitive code goes through Bob_runtime.fork. A bare Eio.Fiber.fork in
   cognitive code is a bug, and test_runtime asserts that it fails loudly. *)

type trace_entry = string * float
type trace = { mutable entries : trace_entry list }

let new_trace () = { entries = [] }
let trace_entries t = List.rev t.entries
let trace_names t = List.rev_map fst t.entries |> List.rev

(* §20 + correction C5.

   A perform inside a handler escapes OUTWARD to the enclosing handler, so
   tracing must nest INSIDE the interpreting handler:

     with_sim (fun () -> with_tracing (fun () -> f ()))   captures
     with_tracing (fun () -> with_sim (fun () -> f ()))   captures NOTHING

   The wrong order does not error, so getting it backwards is a silent
   failure. Only names and durations are recorded: §20 forbids logging raw
   prompts or audio. *)
let with_tracing trace f =
  match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match Bob_effect.name_of e with
          | None -> None
          | Some name ->
              Some
                (fun (k : (a, _) continuation) ->
                  let t0 = Unix.gettimeofday () in
                  (* Re-perform: the enclosing interpreting handler services it. *)
                  let v = Effect.perform e in
                  let dt = (Unix.gettimeofday () -. t0) *. 1000. in
                  trace.entries <- (name, dt) :: trace.entries;
                  continue k v)) }

let maybe_trace trace f =
  match trace with None -> f | Some tr -> fun () -> with_tracing tr f

(* Install the sim handler stack around f. Interpreting handler outside,
   tracing inside (C5). *)
let with_sim ?trace ?clock sim sw f =
  Bob_handler_sim.handle sim ?clock sw (maybe_trace trace f)

(* THE spawn helper. Every fork in cognitive code uses this. *)
let fork ~sw ~sim ?trace ?clock f =
  Eio.Fiber.fork ~sw (fun () -> with_sim ?trace ?clock sim sw f)

(* Run a whole simulated session. The callback receives the switch so it can
   fork further fibers through Bob_runtime.fork. *)
let run_sim ?trace sim f =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run @@ fun sw -> with_sim ?trace ~clock sim sw (fun () -> f sw)
```

Note `Unix.gettimeofday` here is deliberate and does not violate §14: this is
handler-level observability, not cognitive logic. §14 forbids wall-clock reads
in *domain modules*; cognition still gets time via `Bob_effect.Clock.now`.
Add `unix` to the library's dependencies.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `runtime` suite green, 7 tests.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: per-fiber handler runtime and tracing

Corrections C1 and C5, the two places patch 002 does not work as written.

C1: effect handlers do not cross Eio.Fiber.fork, so every fiber installs its
own stack via Bob_runtime.fork. A test asserts that a bare Eio.Fiber.fork
raises Effect.Unhandled, so the helper cannot be quietly simplified away.

C5: tracing nests inside the interpreting handler, because a re-perform
escapes outward. The reverse order captures nothing without erroring, so a
test asserts the trace is non-empty rather than merely that the code runs.
Only effect names and durations are recorded, never prompt text (section 20).

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Effectful cognition

Patch §17 (control remains authoritative), §15 (memory policy is pure,
persistence is effectful), §4 (cognition does not know what backs an effect).

This is the flow the whole patch exists to enable. Note the ordering: the LLM
proposes, `Control.validate` approves, and only then does an effect fire.

**Files:**
- Create: `lib/cognition/dune`, `lib/cognition/bob_cognition.ml`, `test/test_cognition.ml`
- Modify: `test/dune`

- [ ] **Step 1: Write the failing test**

Add `test_cognition` to names, `bob_cognition` to libraries.

Create `test/test_cognition.ml`:

```ocaml
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
       (fun q ->
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `Library "bob_cognition" not found.`

- [ ] **Step 3: Implement cognition**

Create `lib/cognition/dune`:

```
(library
 (name bob_cognition)
 (libraries bob_types bob_events bob_world bob_workspace bob_control bob_project
   bob_effect eio))
```

Create `lib/cognition/bob_cognition.ml`:

```ocaml
open Bob_types

(* Patch 002 §15: memory SELECTION is pure policy. Only the retrieval is
   effectful. This module stays testable without any handler. *)
module Memory_policy = struct
  let queries ~workspace ~utterance =
    let person = Bob_workspace.speaker workspace in
    let topic =
      match Bob_workspace.topic workspace with Some t -> [ t ] | None -> []
    in
    (* The utterance itself is always a query; the topic adds a second when
       the workspace is maintaining one. *)
    List.map
      (fun text -> Bob_effect.Memory.{ text; person })
      (utterance :: topic)
end

(* §4: this function does not know whether Recall hits SQLite or a fixture,
   whether Think reaches OpenRouter or a canned reply, or whether Speak drives
   a speaker or appends to a trace. *)
let handle_utterance ~config ~world ~workspace ~event =
  match event with
  | Bob_events.Utterance u ->
      (* 1. Pure policy decides what to look for. *)
      let qs = Memory_policy.queries ~workspace ~utterance:u.Bob_events.text in
      (* 2. Effectful retrieval. *)
      let items = List.concat_map Bob_effect.Memory.recall qs in
      (* 3. Pure projection: perception becomes meaning (§21 of SPEC). *)
      let now = Bob_effect.Clock.now () in
      let profile =
        match items with
        | [] -> None
        | l -> Some (String.concat "\n" (List.map (fun i -> "- " ^ i.Bob_effect.Memory.text) l))
      in
      let context =
        Bob_project.render ~now ~world ~workspace ~profile ~episodes:[]
      in
      (* 4. Effectful inference, streamed. *)
      let stream =
        Bob_effect.Brain.think
          Bob_effect.Brain.
            { context; utterance = u.Bob_events.text; speaker = u.Bob_events.speaker }
      in
      (* 5. Collect the reply. A Failed chunk at any position ends it (C4). *)
      let buf = Buffer.create 128 in
      let failed = ref None in
      let rec drain () =
        match Eio.Stream.take stream with
        | Bob_effect.Brain.Text t ->
            if Buffer.length buf > 0 then Buffer.add_char buf ' ';
            Buffer.add_string buf t;
            drain ()
        | Bob_effect.Brain.Failed e -> failed := Some e
      in
      drain ();
      let reply = Buffer.contents buf in
      (* 6. §17: the brain PROPOSES; Control validates; only then do we act. *)
      if reply <> "" then (
        match Bob_control.validate ~config (Bob_control.Say reply) with
        | Error _ -> () (* rejected: nothing reaches the body or speaker *)
        | Ok (Bob_control.Say approved) ->
            (* Fill-then-perform: no fiber is spawned, so the handler stack is
               intact. Capacity must exceed the item count or Stream.add
               blocks forever with no consumer. See correction C1. *)
            let out = Eio.Stream.create 4 in
            Eio.Stream.add out (Bob_effect.Speech.Say approved);
            Eio.Stream.add out Bob_effect.Speech.End;
            ignore (Bob_effect.Speech.say out)
        | Ok _ -> ())
  | _ -> ()
```

**Note on step 6.** It fills the stream and *then* performs, spawning no
fiber. This is deliberate: `Fiber.fork`, `Fiber.both` and `Fiber.first` all
break the handler chain (correction C1 — verified; `both` and `first` fail
exactly as `fork` does). Do not "simplify" this into a `Fiber.both`
producer/consumer pair; it will raise `Effect.Unhandled` at runtime.

The stream capacity (4) must stay above the number of items added (2), since
`Stream.add` on a full stream blocks forever when nothing is consuming.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `cognition` suite green, 5 tests.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: effectful cognition flow

Memory selection is pure policy; only retrieval is effectful (section 15).
The brain proposes, Control.validate approves, and only an approved action
reaches the speaker or body (section 17) - tested by proposing an overlong
utterance and asserting nothing is spoken.

Cognition does not know what backs any effect (section 4): the same function
runs under sim, replay and live handlers.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Replay handlers

Patch §7 (replay environment), §8 (a recorded interaction replays without
hardware, network or an LLM), and acceptance criterion 7.

Replay substitutes recorded results for effects and asserts actions against
expectations.

**Files:**
- Create: `lib/handler_replay/dune`, `lib/handler_replay/bob_handler_replay.ml`, `test/test_handler_replay.ml`
- Modify: `test/dune`

- [ ] **Step 1: Write the failing test**

Add `test_handler_replay` to names, `bob_handler_replay` to libraries.

Create `test/test_handler_replay.ml`:

```ocaml
open Bob_types

let at ms = Time.of_ms ms

let recording =
  Bob_handler_replay.
    { times = [ at 0.; at 1680. ];
      recalls = [ [ Bob_effect.Memory.{ text = "workshop"; source = "profile" } ] ];
      thinks = [ "It is in the workshop." ];
      identities = [ Bob_effect.Identity.Matched (Person_id.v "gustaf", Confidence.v 0.9) ] }

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
            Bob_effect.Brain.{ context = ""; utterance = ""; speaker = None } in
        let b = Buffer.create 64 in
        let rec d () =
          match Eio.Stream.take s with
          | Bob_effect.Brain.Text t ->
              if Buffer.length b > 0 then Buffer.add_char b ' ';
              Buffer.add_string b t; d ()
          | Bob_effect.Brain.Failed _ -> ()
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
              Bob_effect.Brain.{ context = ""; utterance = ""; speaker = None }))
   with Bob_handler_replay.Exhausted _ -> raised := true);
  Alcotest.(check bool) "raised Exhausted" true !raised

let test_actions_are_asserted_against_expectations () =
  let r = Bob_handler_replay.create recording in
  Bob_handler_replay.run r (fun () ->
      ignore (Bob_effect.Body.look_at Bob_effect.Body.Neutral))
  |> ignore;
  match Bob_handler_replay.actions r with
  | [ Bob_handler_replay.Looked Bob_effect.Body.Neutral ] -> ()
  | l -> Alcotest.failf "expected one Looked, got %d" (List.length l)

let () =
  Alcotest.run "handler_replay"
    [ ("recorded",
       [ Alcotest.test_case "time in order" `Quick test_recorded_time_is_returned_in_order;
         Alcotest.test_case "think replayed" `Quick test_recorded_think_is_replayed;
         Alcotest.test_case "exhausted raises" `Quick test_exhausted_recording_raises;
         Alcotest.test_case "actions recorded" `Quick
           test_actions_are_asserted_against_expectations ]) ]
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `Library "bob_handler_replay" not found.`

- [ ] **Step 3: Implement replay**

Create `lib/handler_replay/dune`:

```
(library
 (name bob_handler_replay)
 (libraries bob_types bob_effect eio eio_main))
```

Create `lib/handler_replay/bob_handler_replay.ml`:

```ocaml
open Bob_types
open Effect.Deep

(* Patch 002 §7 replay environment, §8 replayability.

   A recorded interaction must run with no hardware, no network and no LLM.
   Running out of recorded results is an ERROR, never a silent fallback -- a
   replay that quietly starts behaving live is worse than one that stops. *)

exception Exhausted of string

type recording = {
  times : Time.t list;
  recalls : Bob_effect.Memory.item list list;
  thinks : string list;
  identities : Bob_effect.Identity.result list;
}

type action = Looked of Bob_effect.Body.target | Spoke of string

type t = {
  mutable times : Time.t list;
  mutable recalls : Bob_effect.Memory.item list list;
  mutable thinks : string list;
  mutable identities : Bob_effect.Identity.result list;
  mutable actions : action list;
}

let create (r : recording) =
  { times = r.times; recalls = r.recalls; thinks = r.thinks;
    identities = r.identities; actions = [] }

let actions t = List.rev t.actions

let pop name lst =
  match !lst with
  | [] -> raise (Exhausted name)
  | x :: rest ->
      lst := rest;
      x

let words s = String.split_on_char ' ' s |> List.filter (fun w -> w <> "")

let handle t _sw f =
  match_with f ()
    { retc = (fun v -> v);
      exnc = raise;
      effc =
        (fun (type a) (e : a Effect.t) ->
          match e with
          | Bob_effect.Now ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.times in
                  let v = pop "Now" r in
                  t.times <- !r;
                  continue k v)
          | Bob_effect.Recall _ ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.recalls in
                  let v = pop "Recall" r in
                  t.recalls <- !r;
                  continue k v)
          | Bob_effect.Think _ ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.thinks in
                  let reply = pop "Think" r in
                  t.thinks <- !r;
                  let s = Eio.Stream.create (List.length (words reply) + 2) in
                  List.iter (fun w -> Eio.Stream.add s (Bob_effect.Brain.Text w)) (words reply);
                  Eio.Stream.add s (Bob_effect.Brain.Failed Bob_effect.Brain.Invalid_response);
                  continue k s)
          | Bob_effect.Speak stream ->
              Some
                (fun (k : (a, _) continuation) ->
                  let b = Buffer.create 64 in
                  let rec d () =
                    match Eio.Stream.take stream with
                    | Bob_effect.Speech.End -> ()
                    | Bob_effect.Speech.Say s -> Buffer.add_string b s; d ()
                  in
                  d ();
                  t.actions <- Spoke (Buffer.contents b) :: t.actions;
                  continue k (Ok ()))
          | Bob_effect.Look_at target ->
              Some
                (fun (k : (a, _) continuation) ->
                  t.actions <- Looked target :: t.actions;
                  continue k (Ok ()))
          | Bob_effect.Identify _ ->
              Some
                (fun (k : (a, _) continuation) ->
                  let r = ref t.identities in
                  let v = pop "Identify" r in
                  t.identities <- !r;
                  continue k v)
          | _ -> None) }

let run t f = Eio_main.run @@ fun _env -> Eio.Switch.run @@ fun sw -> handle t sw f

(* `handle` takes the switch for signature symmetry with the sim handler even
   though replay spawns no fiber: every chunk is added to a stream sized to
   hold all of them, so nothing blocks and nothing needs forking. *)
```

Note the `Think` stream is sized to hold every chunk plus the terminator, so
no `Stream.add` blocks — there is no consumer fiber (correction C1).

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `handler_replay` suite green, 4 tests.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: replay effect handlers

Recorded results substitute for effects so a whole interaction runs with no
hardware, network or LLM (patch 002 sections 7 and 8, acceptance criterion 7).

Exhausting the recording raises Exhausted rather than falling back to live
behaviour: a replay that quietly starts making real calls is worse than one
that stops.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: Live handlers (compile-only)

Patch §7 (live environment), §9 (the handler owns provider, model, auth,
transport, retry, timeouts), §13 (cancellation), §19 (typed errors).

**This task builds code that cannot be run here.** There is no OpenRouter key,
no TTS, no OpenRB hardware and no vision worker on this machine. Correction C6
splits acceptance criterion 6 accordingly: 6a (sim + replay) is testable now,
6b (live) stays **PENDING**.

Do not claim the live path works because it compiles.

**Files:**
- Create: `lib/handler_live/dune`, `lib/handler_live/bob_handler_live.ml`
- Create: `test/test_handler_live.ml`

- [ ] **Step 1: Confirm no HTTP client is needed yet**

This task writes NO transport. The code below uses only `yojson` for request
construction and SSE parsing, both already installed. **Do not install
`cohttp-eio`** — an unused dependency that cannot be exercised here is exactly
the kind of unvalidated claim correction C6 exists to prevent.

Run: `opam list --installed 2>/dev/null | grep -E "^yojson"`
Expected: `yojson 3.0.0`. If absent, STOP and report.

The HTTP client gets chosen and installed when the transport is actually
wired, against a real endpoint.

- [ ] **Step 2: Write the failing test**

Add `test_handler_live` to names, `bob_handler_live` to libraries.

Create `test/test_handler_live.ml`:

```ocaml
(* These tests do NOT contact OpenRouter. They check the parts of the live
   handler that are testable without credentials: request construction, error
   mapping, and that the module's surface matches what cognition expects.

   Live end-to-end validation is PENDING (correction C6). *)

let test_config_requires_an_api_key () =
  match Bob_handler_live.Brain.config_of_env ~getenv:(fun _ -> None) with
  | Error _ -> ()
  | Ok _ -> Alcotest.fail "expected an error when OPENROUTER_API_KEY is unset"

let test_config_reads_model_from_env () =
  match
    Bob_handler_live.Brain.config_of_env ~getenv:(function
      | "OPENROUTER_API_KEY" -> Some "sk-test"
      | "BOB_BRAIN_MODEL" -> Some "some/model"
      | _ -> None)
  with
  | Ok c -> Alcotest.(check string) "model" "some/model" c.Bob_handler_live.Brain.model
  | Error m -> Alcotest.failf "unexpected error: %s" m

let test_request_body_contains_the_projected_context () =
  let c =
    Bob_handler_live.Brain.{ api_key = "sk-test"; model = "m"; base_url = "https://example.invalid" }
  in
  let body =
    Bob_handler_live.Brain.request_body c
      Bob_effect.Brain.{ context = "CURRENT\nGustaf is speaking."; utterance = "where?";
                         speaker = None }
  in
  let contains h n =
    let nl = String.length n and hl = String.length h in
    let rec go i = i + nl <= hl && (String.sub h i nl = n || go (i + 1)) in
    nl = 0 || go 0
  in
  Alcotest.(check bool) "context present" true (contains body "Gustaf is speaking");
  Alcotest.(check bool) "utterance present" true (contains body "where?");
  Alcotest.(check bool) "streaming requested" true (contains body "\"stream\":true")

(* §19: HTTP failures become typed domain errors, not raw exceptions. *)
let test_status_codes_map_to_typed_errors () =
  let m = Bob_handler_live.Brain.error_of_status in
  Alcotest.(check string) "429" "rate_limited"
    (Bob_effect.Brain.error_to_string (m 429));
  Alcotest.(check string) "503" "unavailable"
    (Bob_effect.Brain.error_to_string (m 503));
  Alcotest.(check string) "408" "timeout"
    (Bob_effect.Brain.error_to_string (m 408));
  Alcotest.(check string) "400" "invalid_response"
    (Bob_effect.Brain.error_to_string (m 400))

let test_sse_line_parsing () =
  (* OpenRouter streams server-sent events; the handler must extract deltas
     and recognise the terminator. *)
  Alcotest.(check (option string)) "content delta" (Some "Hello")
    (Bob_handler_live.Brain.parse_sse_line
       {|data: {"choices":[{"delta":{"content":"Hello"}}]}|});
  Alcotest.(check (option string)) "done" None
    (Bob_handler_live.Brain.parse_sse_line "data: [DONE]");
  Alcotest.(check (option string)) "comment ignored" None
    (Bob_handler_live.Brain.parse_sse_line ": keep-alive")

let () =
  Alcotest.run "handler_live"
    [ ("config",
       [ Alcotest.test_case "requires key" `Quick test_config_requires_an_api_key;
         Alcotest.test_case "reads model" `Quick test_config_reads_model_from_env ]);
      ("request",
       [ Alcotest.test_case "carries context" `Quick
           test_request_body_contains_the_projected_context ]);
      ("errors",
       [ Alcotest.test_case "status mapping" `Quick test_status_codes_map_to_typed_errors ]);
      ("sse", [ Alcotest.test_case "line parsing" `Quick test_sse_line_parsing ]) ]
```

- [ ] **Step 3: Implement the live handler**

Create `lib/handler_live/dune`:

```
(library
 (name bob_handler_live)
 (libraries bob_effect yojson))
```

Create `lib/handler_live/bob_handler_live.ml`:

```ocaml
(* Patch 002 §7 live environment and §9: the handler owns provider, model,
   authentication, transport, retry and timeouts. Cognition knows none of it.

   STATUS: compiles, NOT validated end to end. No OpenRouter key, no TTS, no
   OpenRB hardware and no vision worker exist on the development machine.
   Correction C6: acceptance criterion 6b stays PENDING. *)

module Brain = struct
  type config = { api_key : string; model : string; base_url : string }

  let default_base_url = "https://openrouter.ai/api/v1"
  let default_model = "anthropic/claude-sonnet-5"

  let config_of_env ~getenv =
    match getenv "OPENROUTER_API_KEY" with
    | None | Some "" -> Error "OPENROUTER_API_KEY is not set"
    | Some api_key ->
        Ok
          { api_key;
            model = (match getenv "BOB_BRAIN_MODEL" with Some m when m <> "" -> m | _ -> default_model);
            base_url =
              (match getenv "BOB_BRAIN_BASE_URL" with Some u when u <> "" -> u | _ -> default_base_url) }

  (* §9: Brain.request already contains the projected context. The handler
     only shapes it for the wire. *)
  let request_body c (r : Bob_effect.Brain.request) =
    let system = `String r.Bob_effect.Brain.context in
    Yojson.Safe.to_string
      (`Assoc
        [ ("model", `String c.model);
          ("stream", `Bool true);
          ( "messages",
            `List
              [ `Assoc [ ("role", `String "system"); ("content", system) ];
                `Assoc
                  [ ("role", `String "user");
                    ("content", `String r.Bob_effect.Brain.utterance) ] ] ) ])

  (* §19: operational failures become typed domain errors. *)
  let error_of_status = function
    | 429 -> Bob_effect.Brain.Rate_limited
    | 408 | 504 -> Bob_effect.Brain.Timeout
    | s when s >= 500 -> Bob_effect.Brain.Unavailable
    | _ -> Bob_effect.Brain.Invalid_response

  (* OpenRouter streams server-sent events. Returns the content delta, or None
     for terminators, comments and anything unparseable. *)
  let parse_sse_line line =
    let prefix = "data: " in
    let pl = String.length prefix in
    if String.length line <= pl || String.sub line 0 pl <> prefix then None
    else
      let payload = String.sub line pl (String.length line - pl) in
      if payload = "[DONE]" then None
      else
        match Yojson.Safe.from_string payload with
        | exception _ -> None
        | json -> (
            match json with
            | `Assoc kvs -> (
                match List.assoc_opt "choices" kvs with
                | Some (`List (`Assoc c :: _)) -> (
                    match List.assoc_opt "delta" c with
                    | Some (`Assoc d) -> (
                        match List.assoc_opt "content" d with
                        | Some (`String s) when s <> "" -> Some s
                        | _ -> None)
                    | _ -> None)
                | _ -> None)
            | _ -> None)
end

(* The live handler itself is deferred: wiring cohttp-eio streaming, the TTS
   process and the OpenRB serial link cannot be validated on this machine, and
   patch 002 forbids claiming a capability that has not been exercised.

   What exists above is the part that IS testable without credentials:
   configuration, request construction, error mapping and SSE parsing.

   The remaining work, to be done when credentials and hardware exist:
     - Brain.handle : config -> sw -> Eio.Switch.t -> ... forking a fiber that
       reads the SSE body and adds Text chunks to the stream as they arrive,
       so the consumer starts before generation finishes (§10), with
       Eio cancellation propagating to the HTTP request (§13).
     - Memory.handle backed by Bob_memory (SQLite), which CAN be written now.
     - Body.handle over the OpenRB serial protocol.
     - Speech.handle driving TTS.
   Record progress in docs/patches/002-...-CORRECTIONS.md under C6. *)
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `handler_live` suite green, 6 tests.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: live brain handler, configuration and wire format

Configuration from environment, OpenRouter request construction with
streaming requested, typed error mapping from HTTP status, and server-sent
event parsing. All testable without credentials, and tested.

The handler's transport is deliberately NOT wired: no API key, no TTS, no
OpenRB and no vision worker exist on this machine, and patch 002 forbids
claiming a capability that has not been exercised. Acceptance criterion 6b
stays PENDING per correction C6.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Migrate the replay driver and retire the capability records

Acceptance criteria 1, 8 and 11. The existing `bob_trace` replay driver and
`bin/bob_replay.ml` still use the Phase 0 capability records. Migrate them to
effects without changing observable behaviour.

**Files:**
- Modify: `lib/trace/bob_trace.ml`, `lib/trace/dune`
- Modify: `bin/bob_replay.ml`, `bin/dune`
- Modify: `test/test_trace.ml`, `test/test_audit.ml`, `test/test_invariants.ml`
- Modify: `lib/capability/bob_capability.ml`

- [ ] **Step 1: Confirm the current behaviour before changing it**

Run: `opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace`

Record the exact DECISIONS, BODY, SPEECH and LATENCY output. The migration
must reproduce it. In particular Bob's `look` decision must still fire at
`0.000s` and no `interrupt_speech` may appear on the first `speech_started`.

- [ ] **Step 2: Migrate `Bob_trace.replay` to effects**

Change the signature from taking capability records:

```ocaml
val replay : brain:... -> body:... -> tts:... -> memory:... -> Bob_events.t list -> result
```

to taking none — the handler stack supplies them:

```ocaml
val replay :
  ?config:Bob_control.config ->
  ?ttl:Bob_world.ttl ->
  ?ws_config:Bob_workspace.config ->
  Bob_events.t list ->
  result
```

Inside `execute`, replace each capability call with its effect wrapper:

| Was | Becomes |
|---|---|
| `body.Bob_capability.Body.send (Look {yaw; pitch})` | `Bob_effect.Body.look_at (Bob_effect.Body.Bearing yaw)` |
| `tts.Bob_capability.Tts.speak s` | fill a stream, then `Bob_effect.Speech.say` |
| `tts.Bob_capability.Tts.stop ()` | leave as a decision record; cancellation is Task 8 |
| `brain.Bob_capability.Brain.think req` | `Bob_effect.Brain.think req` then drain |
| `Bob_memory.read_profile store p` | `Bob_effect.Memory.recall {text; person}` |

Keep the pre-event world fix — `Bob_control.decide` still receives
`world_before`, not the post-apply world.

- [ ] **Step 3: Update the callers**

`bin/bob_replay.ml` wraps its run in `Bob_runtime.run_sim` with a
`Bob_handler_sim` configured with the same fixed reply it used before, and
reads actions from `Bob_handler_sim.actions` instead of the fake logs.

Tests in `test_trace.ml`, `test_audit.ml` and `test_invariants.ml` do the
same. The assertions themselves do not change — only how the doubles are
supplied.

- [ ] **Step 4: Reduce `bob_capability` to the authority layer**

Patch §5 and §11: capability *modules* still express what a subsystem may do.
Replace each record's body with a thin wrapper that performs the effect, and
delete the `fake` constructors, which the sim handler now supersedes:

```ocaml
(* Patch 002 §5: types and modules express WHAT a subsystem may do; effects
   express WHAT IT REQUESTS; handlers decide HOW it executes. OCaml effects
   are not statically tracked, so a subsystem that must not move Bob is denied
   the Body capability here rather than relying on it not performing Look_at. *)

module type CONVERSATION_CAPABILITIES = sig
  val recall : Bob_effect.Memory.query -> Bob_effect.Memory.item list
  val think : Bob_effect.Brain.request -> Bob_effect.Brain.response
  val speak : Bob_effect.Speech.stream -> (unit, Bob_effect.Speech.error) result
end

module Conversation_with_body : CONVERSATION_CAPABILITIES = struct
  let recall = Bob_effect.Memory.recall
  let think = Bob_effect.Brain.think
  let speak = Bob_effect.Speech.say
end
```

- [ ] **Step 5: Verify behaviour is unchanged**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: every suite green. The pre-existing 101 tests must still pass.

Run: `opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace`
Expected: byte-identical DECISIONS, BODY, SPEECH and LATENCY sections to
Step 1. If anything differs, the migration changed behaviour — investigate
rather than updating the expectation.

- [ ] **Step 6: Commit**

```bash
jj commit -m "Bob: migrate the replay driver to effects

Bob_trace.replay no longer takes capability records; the handler stack
supplies them. Observable behaviour is unchanged: bob-replay produces
byte-identical output, including the orientation decision at 0.000s and no
spurious interrupt on the first speech onset.

Capability modules survive as the authority layer (sections 5 and 11): OCaml
effects are not statically tracked, so a subsystem that must not move Bob is
denied the Body capability rather than trusted not to perform Look_at.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 8: Cancellation

Patch §13: a blocking effect must be cancellable through its Eio context, and
barge-in must propagate — speech fiber cancelled, TTS stops, audio stops.

Verified during planning: `Eio.Time.with_timeout_exn` around a blocking effect
cancels correctly, including mid-stream.

**Files:**
- Create: `test/test_cancellation.ml`
- Modify: `test/dune` only — `lib/handler_sim` already supports pacing from Task 2

- [ ] **Step 1: Write the failing test**

Add `test_cancellation` to names.

Create `test/test_cancellation.ml`:

```ocaml
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `chunk_delay` and `run_with_clock` do not exist.

- [ ] **Step 3: Add a slow mode to the sim handler**

In `lib/handler_sim/bob_handler_sim.ml`:

**Nothing needs adding — Task 2 already built this.** `chunk_delay`,
`?clock`, `pace` and `run_with_clock` exist from Task 2 precisely so this
task changes no signature, and speech already records incrementally so a
cancelled utterance leaves evidence of what was actually said.

Verify before writing the tests:

```bash
grep -n "chunk_delay\|run_with_clock" lib/handler_sim/bob_handler_sim.ml
```

If they are absent, Task 2 was implemented from an older draft — add them as
Task 2 specifies rather than inventing a different shape.

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing|tests run|FAIL"`
Expected: PASS — `cancellation` suite green, 3 tests, and all other suites
still green.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: cancellation through blocking effects

An Eio timeout around a slow Think or Speak cancels it mid-stream, and a
later effect still works afterwards (patch 002 section 13). The sim handler
gains a chunk delay so barge-in is exercised rather than asserted.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Patch 002 Definition of Done

Checked against §28's twelve criteria, with corrections C6 applied.

- [ ] 1. `World.apply`, `Workspace.apply` and `Control.decide` are byte-identical to
      their Phase 0 versions. Verify with `jj diff` across the patch.
- [ ] 2. All cognitive time goes through `Bob_effect.Clock.now`. The reducers keep
      their explicit `~now` parameters (C7 — converting them would violate §2 and §26).
- [ ] 3. Brain inference is `Bob_effect.Brain.think`, backed by a handler.
- [ ] 4. Memory recall is `Bob_effect.Memory.recall`, backed by a handler.
- [ ] 5. Speech and body actions are effect-handled.
- [ ] 6a. The same cognitive flow runs under sim and replay handlers. **Testable now.**
- [ ] 6b. The same flow runs under live handlers. **PENDING** — no credentials, no
      hardware. Do not tick this because the code compiles.
- [ ] 7. A recorded interaction replays with no hardware, network or LLM.
- [ ] 8. Brain output passes `Control.validate` before any physical action, proven
      by a test that proposes an invalid action and asserts nothing is emitted.
- [ ] 9. Streaming is preserved: the sim brain handler yields chunks progressively.
- [ ] 10. Eio cancellation propagates through blocking effects.
- [ ] 11. Capability modules still gate authority; a subsystem denied the body
      capability cannot move Bob.
- [ ] 12. No generic effect framework: six effects, one `Effect.perform` site.

Plus:

- [ ] `opam exec -- dune build` clean.
- [ ] `opam exec -- dune test` green, including the 101 pre-existing tests.
- [ ] `bob-replay` output byte-identical to before the patch.
- [ ] A test asserts a bare `Eio.Fiber.fork` in cognitive code raises
      `Effect.Unhandled` (C1), so the spawn helper cannot be simplified away.
- [ ] A test asserts the trace is non-empty (C5), since the wrong handler
      nesting fails silently.

## What this patch does NOT establish

- No live model call has been made. No audio has been produced. Nothing has moved.
- The live handler's transport is unwritten; §13 cancellation is proven against
  the sim handler only.
- SPEC §17's latency budget remains unmeasured. See `bench/README.md`.
