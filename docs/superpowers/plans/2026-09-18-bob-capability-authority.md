# Capability Authority Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Patch 002 criterion 11 true — a subsystem denied the body capability must be unable to move Bob, enforced by the compiler rather than by convention.

**Architecture:** Split `bob_effect` into `bob_domain` (types everyone may see) and `bob_effect` (the six effect constructors and perform wrappers, restricted). `bob_capability` exposes two signatures, `CONVERSATION_CAPABILITIES` and `EMBODIED_CAPABILITIES`. `bob_cognition` and `bob_trace` become functors over those signatures and drop `bob_effect` from their dune stanzas. `(implicit_transitive_deps false)` in `dune-project` is what makes the denial real.

**Tech Stack:** OCaml 5.4.1 (stock `default` switch), dune 3.24, eio 1.5, alcotest.

**Read first:** `docs/superpowers/specs/2026-09-17-capability-authority-design.md`, especially its **Limits** section. The guarantee is narrower than "cognition cannot perform effects" and must not be written up as though it were.

---

## Prerequisites

Already done — do not redo:

- Patch 002 complete: 138 tests, 19 suites, clean build.
- `bob-replay` baseline captured before Patch 002 began, md5 `b27696598fdc61b8c5b5bb5737879aa4`.

**Switch discipline.** The opam switch is directory-local:

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
| Functor over a capability signature; effects still reach the handler | works |
| Functor ALONE denies body access | **NO — the attack compiled and moved Bob** |
| Same attack under `(implicit_transitive_deps false)` | `Unbound module "Bob_effect"` |
| Cost of that flag on this tree | 4 errors, all `Unbound module Eio`, all in `test/` |
| Three-layer domain / effect / capability stack builds | works |
| Cognition over a capability signature naming the ops library | `Unbound module "E"` |
| `EMBODIED` including `CONVERSATION`; both functors instantiate | works |
| Conversation-only functor naming `C.look_at` | `Unbound value "C.look_at"` |
| Self-declared effect performed inside a full handler stack | `Effect.Unhandled`, 0 actions |
| Bare `ocamlfind` compile-fail rule | **passes for the WRONG reason** — fails on `Bob_capability`, the first unbound module, so it would pass with the leak open |
| `runtest` rule shelling out to `dune build` | **always passes** — the nested dune cannot take the build lock, so it always "fails" |
| `enabled_if` library probe + standalone script, leak closed | correct denial, script exit 0 |
| Same, leak reopened (dep added back) | script exit 1, correctly caught |

The second row is why this plan exists in the shape it does. The functor is
the visible half; the dune flag is the load-bearing half.

---

## File Structure

```
lib/
  domain/       bob_domain      Types only: Memory, Brain, Speech, Body,
                                Identity — request/response/chunk/target/
                                error types and error_to_string.
                                Deps: bob_types, eio.

  effect/       bob_effect      The six `type _ Effect.t +=` declarations,
                                the six perform wrappers, and name_of.
                                No types of its own. THE RESTRICTED LIBRARY.
                                Deps: bob_types, bob_domain, eio.

  capability/   bob_capability  CONVERSATION_CAPABILITIES (recall, think,
                                speak, now) and EMBODIED_CAPABILITIES
                                (those plus look_at), with implementations
                                forwarding to the wrappers.
                                Deps: bob_types, bob_domain, bob_effect.

  cognition/    bob_cognition   Make (C : CONVERSATION_CAPABILITIES).
                                Deps: ..., bob_domain, bob_capability.
                                NOT bob_effect.

  trace/        bob_trace       Make (C : EMBODIED_CAPABILITIES) — replay
                                drives the body, so it needs the stronger
                                grant. Deps: ..., bob_domain, bob_capability.
                                NOT bob_effect.

test/
  deny/         compile-fail test: a module naming Bob_effect while
                depending only on bob_domain + bob_capability must NOT build.
```

**Unchanged:** every handler (`bob_handler_sim`, `bob_handler_replay`,
`bob_handler_live`) and `bob_runtime` keep depending on `bob_effect`. They
interpret effects and need the constructors. That asymmetry is the design.

**Frozen, must not change:** `lib/types`, `lib/events`, `lib/world`,
`lib/workspace`, `lib/control`, `lib/project`, `lib/memory`, `lib/obs`.
Patch 002 criterion 1 depends on it.

---

### Task 1: Extract `bob_domain`

**Files:**
- Create: `lib/domain/dune`, `lib/domain/bob_domain.ml`
- Modify: `lib/effect/dune`, `lib/effect/bob_effect.ml`

This task is a pure move: the type modules leave `bob_effect` for
`bob_domain`, and `bob_effect` refers to them by their new home. No behaviour
changes, so the existing 138 tests are the test — they must stay green
without being edited.

- [ ] **Step 1: Create the domain library**

Create `lib/domain/dune`:

```
(library
 (name bob_domain)
 (libraries bob_types eio))
```

Create `lib/domain/bob_domain.ml`. These are the `Memory0`/`Brain0`/etc.
modules from `bob_effect.ml` verbatim, renamed to their public names:

```ocaml
open Bob_types

(* Patch 002 §3 domain vocabulary, split out of bob_effect so that modules
   which must NOT be able to act can still name the types they exchange.

   This library holds types ONLY. The effect constructors and the perform
   wrappers live in bob_effect, which cognition and the replay driver are
   deliberately unable to depend on. See
   docs/superpowers/specs/2026-09-17-capability-authority-design.md *)

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
```

- [ ] **Step 2: Reduce `bob_effect` to constructors and wrappers**

Replace `lib/effect/dune` with:

```
(library
 (name bob_effect)
 (libraries bob_types bob_domain eio))
```

Replace the entire contents of `lib/effect/bob_effect.ml` with:

```ocaml
(* Patch 002 §3: a small semantic vocabulary. Six effects. §25 forbids
   growing this into a framework.

   §6: Effect.perform appears ONLY in this file.

   The TYPES live in bob_domain. This library is the restricted one: a module
   that can name Bob_effect can act, so cognition and the replay driver do not
   depend on it. Handlers do, because they must pattern-match the
   constructors to interpret them. *)

(* --- The effects. C3: one += per constructor, GADT return on each. --- *)

type _ Effect.t += Now : Bob_types.Time.t Effect.t
type _ Effect.t += Recall : Bob_domain.Memory.query -> Bob_domain.Memory.item list Effect.t
type _ Effect.t += Think : Bob_domain.Brain.request -> Bob_domain.Brain.response Effect.t

type _ Effect.t +=
  | Speak : Bob_domain.Speech.stream -> (unit, Bob_domain.Speech.error) result Effect.t

type _ Effect.t +=
  | Look_at : Bob_domain.Body.target -> (unit, Bob_domain.Body.error) result Effect.t

type _ Effect.t +=
  | Identify : Bob_domain.Identity.request -> Bob_domain.Identity.result Effect.t

(* --- §6: typed wrappers. Nothing outside this file calls perform. --- *)

module Clock = struct
  let now () = Effect.perform Now
end

module Memory = struct
  let recall q = Effect.perform (Recall q)
end

module Brain = struct
  let think r = Effect.perform (Think r)
end

module Speech = struct
  let say s = Effect.perform (Speak s)
end

module Body = struct
  let look_at t = Effect.perform (Look_at t)
end

module Identity = struct
  let identify r = Effect.perform (Identify r)
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

Note the module names are now `Bob_effect.Memory` (operations) and
`Bob_domain.Memory` (types). The staging trick with `Memory0` is gone: there
is no longer a name collision, because the types moved out.

- [ ] **Step 3: Repoint every consumer at the new type home**

Every file that names a TYPE through `Bob_effect` must now name it through
`Bob_domain`. Operation calls — `Bob_effect.Memory.recall`,
`Bob_effect.Brain.think`, `Bob_effect.Speech.say`, `Bob_effect.Body.look_at`,
`Bob_effect.Identity.identify`, `Bob_effect.Clock.now` — stay as they are for
now; Tasks 3 and 4 route those through capabilities.

Add `bob_domain` to the `(libraries ...)` of each of these dune files:
`lib/capability/dune`, `lib/handler_sim/dune`, `lib/handler_replay/dune`,
`lib/handler_live/dune`, `lib/runtime/dune`, `lib/cognition/dune`,
`lib/trace/dune`, `bin/dune`, `test/dune`.

Then rewrite the type references. The mechanical rule: a reference is a TYPE
reference if it names `query`, `item`, `request`, `response`, `chunk`,
`stream`, `target`, `result`, `error`, a constructor (`Text`, `Failed`, `Say`,
`End`, `Bearing`, `Neutral`, `Matched`, `Unknown`, `Uncertain`,
`Rate_limited`, `Invalid_response`, `Timeout`, `Unavailable`,
`Device_unavailable`, `Interrupted`, `Unreachable`, `Rejected`,
`Disconnected`, `Worker_unavailable`, `No_face`, `Corrupt`), a record field
(`.text`, `.source`, `.person`, `.context`, `.utterance`, `.speaker`,
`.track`), or `error_to_string`.

Run this to find every site:

```bash
grep -rn "Bob_effect\." lib bin test --include=*.ml | grep -vE "Bob_effect\.(Memory\.recall|Brain\.think|Speech\.say|Body\.look_at|Identity\.identify|Clock\.now|name_of|Now|Recall|Think|Speak|Look_at|Identify)\b"
```

Change each hit from `Bob_effect.X` to `Bob_domain.X`. Note the effect
CONSTRUCTORS (`Bob_effect.Now`, `Bob_effect.Recall`, `Bob_effect.Think`,
`Bob_effect.Speak`, `Bob_effect.Look_at`, `Bob_effect.Identify`) stay on
`Bob_effect` — handlers pattern-match those and they are not types.

This is the fiddliest step in the plan. At the time of writing that grep
returns **100 sites** across the handlers, runtime, cognition, trace, bin and
test files. Work file by file, building after each, rather than with a single
global sed — a wrong global replace here turns an effect constructor into a
type reference and the error messages get confusing fast.

- [ ] **Step 4: Build and test**

Run: `opam exec -- dune build 2>&1 | head -30`
Expected: clean.

Run: `opam exec -- dune test --force 2>&1 | grep -cE "^Test Successful"`
Expected: `19`.

Run: `opam exec -- dune test --force 2>&1 | grep -E "Test Successful" | sed 's/.*in [0-9.]*s\. //' | awk '{s+=$1} END {print s}'`
Expected: `138`.

If any test needed editing to pass, the move was not behaviour-preserving.
Revert the edit and fix the move.

- [ ] **Step 5: Verify `bob-replay` is unchanged**

```bash
opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace | md5sum
```

Expected: `b27696598fdc61b8c5b5bb5737879aa4  -`

If it differs, the move changed behaviour. Investigate; do not update the
expectation.

- [ ] **Step 6: Commit**

```bash
jj commit -m "Bob: split domain types out of bob_effect

bob_domain holds the types every subsystem exchanges; bob_effect keeps only
the six effect constructors, the six perform wrappers and name_of.

This is the split that lets a module name what it is talking about without
being able to act on it, which is the precondition for the capability functor
in the next tasks. Pure move: 138 tests unchanged and bob-replay
byte-identical.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: Turn on explicit dependencies

**Files:**
- Modify: `dune-project`, `test/dune`

This is the load-bearing change. Without it, `bob_effect` is reachable through
the dependency graph from anything that transitively touches it, and every
functor in this plan is decoration. Measured: the body-denial attack compiles
and moves Bob until this flag is set.

- [ ] **Step 1: Set the flag**

In `dune-project`, immediately after `(lang dune 3.24)`, add:

```
(implicit_transitive_deps false)
```

- [ ] **Step 2: Build and see exactly what breaks**

Run: `opam exec -- dune build 2>&1 | grep -E "Unbound module" | sort | uniq -c`
Expected: `4 Error: Unbound module Eio`

All four are in `test/`: `test_cancellation.ml`, `test_handler_replay.ml`,
`test_handler_sim.ml`, `test_runtime.ml`. They use `Eio.Stream` directly but
were relying on it arriving transitively.

- [ ] **Step 3: Add the missing explicit dependency**

In `test/dune`, add `eio` to the `(libraries ...)` list. It already contains
`eio_main`; `eio` itself must now be named too.

- [ ] **Step 4: Build and test**

Run: `opam exec -- dune build 2>&1 | head -20`
Expected: clean.

Run: `opam exec -- dune test --force 2>&1 | grep -cE "^Test Successful"`
Expected: `19`.

If a *library* fails to build rather than a test, add the missing dep to that
library's dune stanza. Do not add `bob_effect` to `bob_cognition` or
`bob_trace` — Tasks 3 and 4 remove those, and re-adding one silently reopens
the leak this whole plan exists to close.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: require dependencies to be declared explicitly

implicit_transitive_deps false. Without this, any library reachable through
the dependency graph is nameable, so a capability signature that omits look_at
denies nothing - the attack compiled and moved Bob.

Cost was four missing eio declarations in the test stanza. The benefit is that
the next two tasks can actually enforce something.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: The capability signatures

**Files:**
- Modify: `lib/capability/dune`, `lib/capability/bob_capability.ml`
- Create: `test/test_capability.ml`
- Modify: `test/dune`

Two signatures. `CONVERSATION_CAPABILITIES` is the weaker grant: recall,
think, speak, now — no body. `EMBODIED_CAPABILITIES` includes it and adds
`look_at`. Including rather than duplicating means a module granted the body
can still instantiate a conversation-only functor, which the replay driver
needs in Task 4.

- [ ] **Step 1: Write the failing test**

Add `test_capability` to the `(names ...)` in `test/dune`.

Create `test/test_capability.ml`:

```ocaml
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `opam exec -- dune test 2>&1 | head -20`
Expected: FAIL — `Unbound module Bob_capability.Conversation` or
`Unbound module type CONVERSATION_CAPABILITIES`.

- [ ] **Step 3: Write the capability layer**

Replace `lib/capability/dune`:

```
(library
 (name bob_capability)
 (libraries bob_types bob_domain bob_effect))
```

Replace the entire contents of `lib/capability/bob_capability.ml`:

```ocaml
(* Patch 002 §5 and §11, and SPEC §1.2 "prefer explicit module injection over
   global singletons".

   Effects are a global singleton: any module that can name Bob_effect can
   perform any effect. This layer is the counterweight. A subsystem takes its
   authority as a module parameter, so what it may do is decided at its
   instantiation site rather than by its own restraint.

   The enforcement has two halves, and BOTH are required:

     1. The signature omits what is denied, so the name is unbound.
     2. dune-project sets (implicit_transitive_deps false), so a functorised
        module cannot reach around its parameter to Bob_effect directly.

   Without (2), (1) is decoration - measured: the attack compiled and moved
   Bob. See docs/superpowers/specs/2026-09-17-capability-authority-design.md,
   including its Limits section: a module may still declare its OWN effect and
   perform it. That compiles, reaches no handler, and raises Effect.Unhandled
   with zero actions recorded. The guarantee is that a subsystem cannot reach
   Bob's body through Bob's own vocabulary, and any route around it fails
   loudly rather than silently. *)

module type CONVERSATION_CAPABILITIES = sig
  val now : unit -> Bob_types.Time.t
  val recall : Bob_domain.Memory.query -> Bob_domain.Memory.item list
  val think : Bob_domain.Brain.request -> Bob_domain.Brain.response
  val speak : Bob_domain.Speech.stream -> (unit, Bob_domain.Speech.error) result
end

(* Everything a conversation may do, plus the body. Including rather than
   restating means a module granted the body can still instantiate a
   conversation-only functor, which the replay driver relies on. *)
module type EMBODIED_CAPABILITIES = sig
  include CONVERSATION_CAPABILITIES

  val look_at : Bob_domain.Body.target -> (unit, Bob_domain.Body.error) result
end

module Conversation : CONVERSATION_CAPABILITIES = struct
  let now = Bob_effect.Clock.now
  let recall = Bob_effect.Memory.recall
  let think = Bob_effect.Brain.think
  let speak = Bob_effect.Speech.say
end

module Embodied : EMBODIED_CAPABILITIES = struct
  include Conversation

  let look_at = Bob_effect.Body.look_at
end

(* Perception has no consumer yet: the vision worker arrives in Phase 3.
   The signature is here so that when it does, identity resolution is granted
   deliberately rather than by default. It gates nothing today, and this
   comment exists so nobody claims otherwise. *)
module type PERCEPTION_CAPABILITIES = sig
  val identify : Bob_domain.Identity.request -> Bob_domain.Identity.result
end

module Perception : PERCEPTION_CAPABILITIES = struct
  let identify = Bob_effect.Identity.identify
end
```

Add `bob_capability` and `bob_domain` to `test/dune`'s `(libraries ...)` if
they are not already there.

- [ ] **Step 4: Run the tests**

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing \`capability|tests run|FAIL"`
Expected: PASS — `capability` suite green, 4 tests.

Run: `opam exec -- dune test --force 2>&1 | grep -cE "^Test Successful"`
Expected: `20`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: capability signatures with a conversation/embodied split

CONVERSATION_CAPABILITIES grants recall, think, speak and now. EMBODIED
includes it and adds look_at, so a body-granted module still satisfies the
weaker signature.

Perception keeps a signature with no consumer, labelled as gating nothing
until the vision worker exists, rather than being described as authority it
does not yet exercise.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: Functorise cognition

**Files:**
- Modify: `lib/cognition/dune`, `lib/cognition/bob_cognition.ml`
- Modify: `test/test_cognition.ml`

`handle_utterance` moves inside `Make (C : CONVERSATION_CAPABILITIES)` and
calls `C.recall` / `C.think` / `C.speak` / `C.now` instead of the global
wrappers. `Memory_policy` stays outside the functor: it is pure, performs
nothing, and its tests should not need a capability to run.

- [ ] **Step 1: Rewrite cognition as a functor**

Replace `lib/cognition/dune`:

```
(library
 (name bob_cognition)
 (libraries bob_types bob_events bob_world bob_workspace bob_control bob_project
   bob_domain bob_capability eio))
```

Note what is absent: `bob_effect`. That absence is the point of the task, and
Task 6's compile-fail test exists to keep it absent.

Replace `lib/cognition/bob_cognition.ml`:

```ocaml
open Bob_types

(* Patch 002 §15: memory SELECTION is pure policy. Only the retrieval is
   effectful. This module stays testable without any handler OR capability. *)
module Memory_policy = struct
  let queries ~workspace ~utterance =
    let person = Bob_workspace.speaker workspace in
    let topic =
      match Bob_workspace.topic workspace with Some t -> [ t ] | None -> []
    in
    (* The utterance itself is always a query; the topic adds a second when
       the workspace is maintaining one. *)
    List.map
      (fun text -> Bob_domain.Memory.{ text; person })
      (utterance :: topic)
end

(* §4: this functor does not know whether Recall hits SQLite or a fixture,
   whether Think reaches OpenRouter or a canned reply, or whether Speak drives
   a speaker or appends to a trace.

   It also cannot move Bob. CONVERSATION_CAPABILITIES has no look_at, and this
   library does not depend on bob_effect, so the global wrapper is not
   nameable here either. Both halves are required; see
   docs/superpowers/specs/2026-09-17-capability-authority-design.md *)
module Make (C : Bob_capability.CONVERSATION_CAPABILITIES) = struct
  let handle_utterance ~config ~world ~workspace ~event =
    match event with
    | Bob_events.Utterance u ->
        (* 1. Pure policy decides what to look for. *)
        let qs = Memory_policy.queries ~workspace ~utterance:u.Bob_events.text in
        (* 2. Effectful retrieval, through the granted capability. *)
        let items = List.concat_map C.recall qs in
        (* 3. Pure projection: perception becomes meaning (§21 of SPEC). *)
        let now = C.now () in
        let profile =
          match items with
          | [] -> None
          | l ->
              Some
                (String.concat "\n"
                   (List.map (fun i -> "- " ^ i.Bob_domain.Memory.text) l))
        in
        let context =
          Bob_project.render ~now ~world ~workspace ~profile ~episodes:[]
        in
        (* 4. Effectful inference, streamed. *)
        let stream =
          C.think
            Bob_domain.Brain.
              { context; utterance = u.Bob_events.text; speaker = u.Bob_events.speaker }
        in
        (* 5. Collect the reply. A Failed chunk at any position ends it (C4). *)
        let buf = Buffer.create 128 in
        let failed = ref None in
        let rec drain () =
          match Eio.Stream.take stream with
          | Bob_domain.Brain.Text t ->
              if Buffer.length buf > 0 then Buffer.add_char buf ' ';
              Buffer.add_string buf t;
              drain ()
          | Bob_domain.Brain.Failed e -> failed := Some e
        in
        drain ();
        let reply = Buffer.contents buf in
        (* 6. §17: the brain PROPOSES; Control validates; only then do we act. *)
        if reply <> "" then (
          match Bob_control.validate ~config (Bob_control.Say reply) with
          | Error _ -> () (* rejected: nothing reaches the body or speaker *)
          | Ok (Bob_control.Say approved) ->
              (* Fill-then-perform: no fiber is spawned, so the handler stack
                 is intact. Capacity must exceed the item count or Stream.add
                 blocks forever with no consumer. See correction C1. *)
              let out = Eio.Stream.create 4 in
              Eio.Stream.add out (Bob_domain.Speech.Say approved);
              Eio.Stream.add out Bob_domain.Speech.End;
              ignore (C.speak out)
          | Ok _ -> ())
    | _ -> ()
end
```

- [ ] **Step 2: Update the cognition tests to instantiate the functor**

In `test/test_cognition.ml`, add near the top, after the existing `open`:

```ocaml
module Cognition = Bob_cognition.Make (Bob_capability.Conversation)
```

Then change each of the three `Bob_cognition.handle_utterance` call sites to
`Cognition.handle_utterance`. The two `Bob_cognition.Memory_policy.queries`
call sites are unchanged — `Memory_policy` is still a plain module.

Change the two `Bob_effect.Memory.` type references in that file to
`Bob_domain.Memory.`.

**Do not change what any assertion checks.** In particular
`test_invalid_brain_action_never_reaches_the_body` must still assert that an
overlong reply produces no `Spoke` action; it is the criterion 8 guard and it
has been mutation-tested.

- [ ] **Step 3: Build and test**

Run: `opam exec -- dune build 2>&1 | head -20`
Expected: clean.

Run: `opam exec -- dune test --force 2>&1 | grep -E "Testing \`cognition|FAIL"`
Expected: `cognition` suite green, 5 tests.

- [ ] **Step 4: Prove the guard still bites**

The §17 authority guard was mutation-tested before this refactor; confirm the
functor did not weaken it. Temporarily replace the validate line in
`lib/cognition/bob_cognition.ml`:

```ocaml
          match Ok (Bob_control.Say reply) with
```

Run: `opam exec -- dune test --force 2>&1 | grep -E "invalid action blocked"`
Expected: `[FAIL] authority (§17) 0 invalid action blocked.`

Then restore the line to `match Bob_control.validate ~config (Bob_control.Say reply) with`
and re-run: expected `[OK]`.

- [ ] **Step 5: Commit**

```bash
jj commit -m "Bob: cognition takes its authority as a module parameter

handle_utterance moves inside Make (C : CONVERSATION_CAPABILITIES) and calls
the granted capability rather than the global wrappers. The library no longer
depends on bob_effect, so Bob_effect.Body.look_at is not nameable here.

Memory_policy stays outside the functor: it is pure, performs nothing, and its
tests should not need a capability to run.

Re-confirmed by mutation that the section 17 validate guard still fails the
authority test when bypassed.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: Functorise the replay driver

**Files:**
- Modify: `lib/trace/dune`, `lib/trace/bob_trace.ml`
- Modify: `bin/bob_replay.ml`, `bin/dune`
- Modify: `test/test_trace.ml`, `test/test_audit.ml`, `test/test_invariants.ml`

`Bob_trace.replay` drives the body — `Look_at_angle` is the reflex path — so
it takes `EMBODIED_CAPABILITIES`, the stronger grant. The parsing half of
`bob_trace` (`parse_string`, `parse_file`) performs nothing and must stay
outside the functor, because `bin/bob_replay.ml` calls `parse_file` before it
has a handler stack to run under.

**This task must not change behaviour.** `bob-replay` output is checked
byte-for-byte.

- [ ] **Step 1: Capture the baseline**

```bash
opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace > /tmp/replay-before.txt 2>&1
md5sum /tmp/replay-before.txt
```

Expected: `b27696598fdc61b8c5b5bb5737879aa4`.

If it differs, an earlier task already broke something. Stop and investigate
before going further.

- [ ] **Step 2: Move the replay driver into a functor**

Replace `lib/trace/dune`:

```
(library
 (name bob_trace)
 (libraries bob_types bob_events bob_world bob_workspace bob_control bob_memory
   bob_project bob_domain bob_capability bob_obs eio))
```

In `lib/trace/bob_trace.ml`, leave everything above the `(* --- Replay driver --- *)`
comment exactly as it is — the parser performs no effects.

Wrap the replay driver in a functor. Immediately after the `type result = {...}`
declaration (which stays at top level, since callers name `Bob_trace.result`),
open the functor and put `replay` inside it:

```ocaml
(* The replay driver drives the body: Look_at_angle is the reflex path, so
   this takes the embodied grant rather than the conversational one. Parsing
   stays outside the functor - bin/bob_replay.ml parses before it has a
   handler stack to run under. *)
module Make (C : Bob_capability.EMBODIED_CAPABILITIES) = struct
  let replay ?(config = Bob_control.default_config)
      ?(ttl = Bob_world.default_ttl)
      ?(ws_config = Bob_workspace.default_config) evs =
    ...
end
```

Inside `replay`'s `execute`, substitute the granted capability for each global
wrapper. The complete list of replacements in this file:

| Was | Becomes |
|---|---|
| `Bob_effect.Body.look_at` | `C.look_at` |
| `Bob_effect.Body.Bearing` | `Bob_domain.Body.Bearing` |
| `Bob_effect.Body.error_to_string` | `Bob_domain.Body.error_to_string` |
| `Bob_effect.Memory.recall` | `C.recall` |
| `Bob_effect.Memory.{ text; person }` | `Bob_domain.Memory.{ text; person }` |
| `i.Bob_effect.Memory.text` | `i.Bob_domain.Memory.text` |
| `Bob_effect.Brain.think` | `C.think` |
| `Bob_effect.Brain.{ context; utterance; speaker }` | `Bob_domain.Brain.{ ... }` |
| `Bob_effect.Brain.Text` / `.Failed` | `Bob_domain.Brain.Text` / `.Failed` |
| `Bob_effect.Brain.error_to_string` | `Bob_domain.Brain.error_to_string` |
| `Bob_effect.Speech.say` | `C.speak` |
| `Bob_effect.Speech.Say` / `.End` | `Bob_domain.Speech.Say` / `.End` |
| `Bob_effect.Speech.error_to_string` | `Bob_domain.Speech.error_to_string` |

Everything else in `replay` — the `world_before` handling, the obs marks, the
`Bob_control.validate` call, the error strings — stays exactly as it is. In
particular **keep passing `world_before` to `Bob_control.decide`**: the
post-apply world produces a spurious self-interrupt, which is a Phase 0
regression with two tests guarding it.

- [ ] **Step 3: Update the callers**

In `bin/dune`, replace `bob_effect` with `bob_domain bob_capability` in the
`(libraries ...)` list. Keep `bob_handler_sim` and `bob_runtime`.

In `bin/bob_replay.ml`, add near the top:

```ocaml
module Replay = Bob_trace.Make (Bob_capability.Embodied)
```

and change `Bob_trace.replay evs` to `Replay.replay evs`. `Bob_trace.parse_file`,
`Bob_trace.decisions`, `Bob_trace.obs` and `Bob_trace.errors` are unchanged.

In `test/test_trace.ml`, `test/test_audit.ml` and `test/test_invariants.ml`,
add the same `module Replay = Bob_trace.Make (Bob_capability.Embodied)` near
the top of each and change `Bob_trace.replay` to `Replay.replay`. Change any
`Bob_effect.` type reference in those files to `Bob_domain.`.

**No assertion changes.** These files contain the two Phase 0 regression
tests — no self-interrupt on first speech onset, and genuine barge-in still
works — plus the audit suite. If one of them fails, the migration is wrong.

- [ ] **Step 4: Build and test**

Run: `opam exec -- dune build 2>&1 | head -20`
Expected: clean.

Run: `opam exec -- dune test --force 2>&1 | grep -cE "^Test Successful"`
Expected: `20`.

Run: `opam exec -- dune test --force 2>&1 | grep -E "Test Successful" | sed 's/.*in [0-9.]*s\. //' | awk '{s+=$1} END {print s}'`
Expected: `142` (138 pre-existing plus Task 3's 4).

- [ ] **Step 5: Verify byte-identical output**

```bash
diff /tmp/replay-before.txt <(opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace 2>&1) && echo IDENTICAL
```

Expected: `IDENTICAL`.

A non-empty diff means the migration changed behaviour. Fix the migration.
Do not update the expectation, and do not re-record the baseline.

- [ ] **Step 6: Commit**

```bash
jj commit -m "Bob: replay driver takes its authority as a module parameter

Bob_trace.Make (C : EMBODIED_CAPABILITIES) - the replay driver drives the
body, so it takes the stronger grant. Parsing stays outside the functor
because bin/bob_replay.ml parses before it has a handler stack.

The library no longer depends on bob_effect. Output is byte-identical,
including the reflex look at 0.000s and no spurious interrupt on the first
speech onset.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: The compile-fail denial test

**Files:**
- Create: `test/deny/dune`, `test/deny/leak.ml`, `test/deny/check-leak.sh`

Everything so far could be undone by one person adding `bob_effect` back to a
dune stanza to fix an unrelated error. This task makes that detectable.

**Two things were measured while designing this task, and both shaped it:**

1. A rule that runs `ocamlfind ocamlopt` on a bare `leak.ml` passes for the
   WRONG reason. `leak.ml` fails on the first unbound module it meets —
   `Bob_capability`, because the rule supplies no library scope — so the test
   would pass even with the `Bob_effect` leak wide open. A compile-fail probe
   must be compiled against the REAL allowed dependency set, or it asserts
   nothing.
2. A `runtest` rule that shells out to `dune build` does not work: the nested
   dune cannot take the build lock, so it always "fails", so the guard always
   "passes". Measured — with the leak deliberately reopened, the nested form
   still reported success while the same script run standalone correctly
   reported failure.

So the probe is a real `(library)` stanza compiled against exactly the
libraries the functorised code may use, gated behind an environment variable
so it is not part of the normal build, and the assertion is a script run
standalone rather than through `dune test`.

- [ ] **Step 1: Write the leak probe**

Create `test/deny/leak.ml`:

```ocaml
(* This file MUST NOT COMPILE. See check-leak.sh in this directory.

   It is the attack the capability layer exists to stop: a module granted only
   conversation reaching around its parameter to the global effect wrapper and
   moving Bob.

   Before (implicit_transitive_deps false), this compiled and worked. That is
   why the flag is in dune-project, and why this probe exists. *)

module Attack (C : Bob_capability.CONVERSATION_CAPABILITIES) = struct
  let move_bob () =
    ignore (Bob_effect.Body.look_at Bob_domain.Body.Neutral);
    ignore C.speak
end
```

Create `test/deny/dune`. The libraries listed are exactly those
`lib/cognition/dune` is allowed — `bob_effect` is deliberately absent, which
is what makes `leak.ml` fail:

```
; The leak probe. Its libraries mirror what a functorised subsystem may
; depend on: bob_domain for types, bob_capability for authority, and NOT
; bob_effect. leak.ml names Bob_effect anyway, so this must not compile.
;
; enabled_if keeps it out of the normal build - a target that is supposed to
; fail cannot be part of `dune build`. check-leak.sh turns it on and asserts
; the failure.
(library
 (name leakprobe)
 (modules leak)
 (libraries bob_types bob_domain bob_capability eio)
 (enabled_if (= %{env:BOB_CHECK_LEAK=false} true)))
```

- [ ] **Step 2: Write the assertion script**

Create `test/deny/check-leak.sh`:

```bash
#!/usr/bin/env bash
# Asserts that test/deny/leak.ml does NOT compile.
#
# leak.ml names Bob_effect.Body.look_at while its dune stanza lists only the
# libraries a functorised subsystem may use. If it compiles, the capability
# boundary is open - most likely because bob_effect was added back to a
# library's dune stanza, or because (implicit_transitive_deps false) was
# removed from dune-project.
#
# Run standalone, NOT from a dune rule: a nested dune cannot take the build
# lock, so it always appears to fail and the guard always appears to pass.
set -u

cd "$(dirname "$0")/../.." || exit 2

if BOB_CHECK_LEAK=true opam exec -- dune build test/deny/ >/dev/null 2>&1; then
  echo "FAIL: test/deny/leak.ml compiled."
  echo "The capability boundary is open. Check that:"
  echo "  - dune-project still sets (implicit_transitive_deps false)"
  echo "  - lib/cognition/dune and lib/trace/dune do not name bob_effect"
  exit 1
fi

echo "OK: test/deny/leak.ml correctly failed to compile."
exit 0
```

Make it executable: `chmod +x test/deny/check-leak.sh`

- [ ] **Step 3: Confirm the normal build ignores the probe**

Run: `opam exec -- dune build 2>&1 | head -5`
Expected: clean. `leakprobe` is disabled without the env var, so a file that
cannot compile does not break the build.

- [ ] **Step 4: Run the guard — it must pass**

Run: `./test/deny/check-leak.sh`
Expected: `OK: test/deny/leak.ml correctly failed to compile.` exit 0.

Confirm it fails for the RIGHT reason — `Bob_effect`, not `Bob_capability`:

```bash
BOB_CHECK_LEAK=true opam exec -- dune build test/deny/ 2>&1 | grep -E "Unbound module"
```

Expected: `Error: Unbound module "Bob_effect"`.

If it says `Unbound module "Bob_capability"` or `Bob_domain`, the probe's dune
stanza is missing a library it should have, and the test is passing for the
wrong reason. Fix the stanza until the only unbound module is `Bob_effect`.

- [ ] **Step 5: Prove the guard catches a reopened leak**

Temporarily add `bob_effect` to `test/deny/dune`'s libraries — this simulates
exactly the mistake the guard exists to catch.

Run: `./test/deny/check-leak.sh; echo "exit=$?"`
Expected: `FAIL: test/deny/leak.ml compiled.` and exit **1**.

Remove `bob_effect` again and re-run: expected `OK` and exit 0.

**Record both observations in the commit message.** A guard nobody has watched
fail is not known to work.

- [ ] **Step 6: Document how to run it**

Append to `README.md` under a `## Checks` heading (create the heading if
absent):

```markdown
### Capability boundary

`./test/deny/check-leak.sh` asserts that a conversation-granted subsystem
cannot name `Bob_effect`. It is not part of `dune test`: the probe must fail
to compile, and a nested `dune` inside a dune rule cannot take the build lock.
Run it directly, and in CI alongside `dune test`.
```

- [ ] **Step 7: Commit**

```bash
jj commit -m "Bob: compile-fail guard for the capability boundary

test/deny/leak.ml names Bob_effect.Body.look_at while its dune stanza lists
only what a functorised subsystem may use. It must not compile;
check-leak.sh asserts that.

Two measured constraints shaped this. A bare ocamlfind probe passes for the
wrong reason - it fails on the first unbound module, Bob_capability, so it
would pass with the leak wide open. And a runtest rule shelling out to dune
always passes, because the nested dune cannot take the build lock; verified
by reopening the leak and watching the nested form report success while the
standalone script correctly failed.

Checked in both directions: OK with the leak closed, exit 1 with bob_effect
added back to the probe stanza.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: Update the Patch 002 definition of done

**Files:**
- Modify: `docs/superpowers/plans/2026-09-16-bob-patch002-effects.md`
- Modify: `docs/patches/002-effect-handled-runtime-CORRECTIONS.md`

Criterion 11 currently reads **NOT MET** with an explanation. This task makes
it accurate — which means ticking it for conversation and body actuation while
being explicit about what is still not gated.

- [ ] **Step 1: Rewrite criterion 11**

In `docs/superpowers/plans/2026-09-16-bob-patch002-effects.md`, replace the
line:

```
- [ ] 11. Capability modules still gate authority. **NOT MET — see below.**
```

with:

```
- [x] 11. Capability modules gate authority for conversation and body
      actuation. `bob_cognition` takes `CONVERSATION_CAPABILITIES` and
      `bob_trace` takes `EMBODIED_CAPABILITIES`; neither library depends on
      `bob_effect`, and `(implicit_transitive_deps false)` stops them reaching
      it transitively. A compile-fail probe in `test/deny/` holds the boundary,
      asserted by `./test/deny/check-leak.sh` and observed to fail when the
      leak is reopened. **Limits:** a module may
      still declare its own effect and perform it — that compiles, reaches no
      handler, and raises `Effect.Unhandled` with zero actions recorded.
      Perception is not gated: `PERCEPTION_CAPABILITIES` has no consumer until
      the vision worker exists.
```

Then replace the whole `### Criterion 11 is not met` section with:

```
### Criterion 11, as met

Done in `docs/superpowers/plans/2026-09-18-bob-capability-authority.md`.

The guarantee is precisely: a subsystem cannot reach Bob's body through Bob's
own effect vocabulary, and any attempt to route around it fails loudly at
runtime rather than silently succeeding. It is not "cognition cannot perform
effects" — OCaml effects are not statically tracked and that guarantee is not
available.

Two halves are required and both are load-bearing: the capability signature
omits the denied operation, and `(implicit_transitive_deps false)` stops the
functorised library naming `Bob_effect` directly. With only the first, the
attack compiles and moves Bob — measured, not assumed.
```

- [ ] **Step 2: Add C10 to the corrections document**

Append to `docs/patches/002-effect-handled-runtime-CORRECTIONS.md`:

```markdown

## C10. A capability functor without explicit dependencies denies nothing

Found while designing the criterion 11 work, before implementing it.

Patch 002 §5 and §11 say capability modules gate authority because "OCaml
effects are not statically tracked, so a subsystem that must not move Bob is
denied the Body capability rather than trusted not to perform Look_at."

**That is not what a functor alone achieves.** A module parameterised over a
signature with no `look_at` can still write
`Bob_effect.Body.look_at Bob_effect.Body.Neutral` and it compiles, because
dune's `implicit_transitive_deps` defaults to `true` and `bob_effect` is
reachable through the dependency graph. Measured: the attack compiled and
moved Bob.

**Correction:** the enforcement has two halves.

1. The capability signature omits the denied operation.
2. `dune-project` sets `(implicit_transitive_deps false)`, and the
   functorised library does not name `bob_effect` in its dune stanza.

With (2) the same attack is `Unbound module "Bob_effect"`. Cost of the flag on
this tree was four missing `eio` declarations in `test/dune`.

This also requires the types to live somewhere a denied module may still see,
hence `bob_domain`: cognition must be able to name `Brain.request` without
being able to perform `Think`.
```

- [ ] **Step 3: Final verification sweep**

```bash
opam exec -- dune build 2>&1 | head -5
opam exec -- dune test --force 2>&1 | grep -cE "^Test Successful"
opam exec -- dune test --force >/dev/null 2>&1; echo "test exit=$?"
diff /tmp/replay-before.txt <(opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace 2>&1) && echo IDENTICAL
grep -rn "bob_effect" lib/cognition/dune lib/trace/dune
```

Expected: clean build; `20` suites; test exit 0; `IDENTICAL`; and the last
grep prints **nothing** — if it prints anything, the leak is open.

- [ ] **Step 4: Commit**

```bash
jj commit -m "Bob: criterion 11 met for conversation and body actuation

Records C10: a capability functor without explicit dependencies denies
nothing, because dune makes bob_effect reachable transitively. Both halves
are load-bearing.

Criterion 11 is ticked with its limits stated: a module may still declare its
own effect, which compiles but reaches no handler; and perception is not
gated until the vision worker exists.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

## Definition of Done

- [ ] `lib/domain/bob_domain.ml` holds the types; `lib/effect/bob_effect.ml`
      holds only constructors, wrappers and `name_of`.
- [ ] `dune-project` sets `(implicit_transitive_deps false)` and the tree builds.
- [ ] `lib/cognition/dune` and `lib/trace/dune` do not name `bob_effect`
      (`grep` prints nothing).
- [ ] `Bob_capability` is referenced from real code — `bin/bob_replay.ml`,
      `test/test_cognition.ml`, `test/test_trace.ml` — not only from its own file.
- [ ] `./test/deny/check-leak.sh` exits 0, failing on `Unbound module
      "Bob_effect"` specifically — not on `Bob_capability`, which would mean
      it passes for the wrong reason.
- [ ] That script has been observed to exit 1 when `bob_effect` is added back
      to `test/deny/dune`.
- [ ] 142 tests across 20 suites green, including all 138 pre-existing.
- [ ] `bob-replay` byte-identical: md5 `b27696598fdc61b8c5b5bb5737879aa4`.
- [ ] The §17 validate guard re-confirmed by mutation after the functor change.
- [ ] Patch 002 criterion 11 updated with its limits; C10 recorded.

## What this does NOT establish

- Perception and body actuation are gated for the replay driver only. No
  vision worker or OpenRB driver exists to be granted or denied anything.
- The denial is compile-time and per-library: it constrains what a module may
  name, not what a fiber may do at runtime.
- A module may declare its own effect and perform it. It reaches no handler,
  but the compiler does not stop it.
- Nothing here has been run against real hardware, a real model, or real
  audio. SPEC §17's latency budget remains unmeasured.
