# Capability authority: making criterion 11 real

**Status:** design, approved 2026-09-17. Supersedes the unused authority layer
left by Patch 002 Task 7.

**Problem:** Patch 002's definition of done claims "capability modules still
gate authority; a subsystem denied the body capability cannot move Bob."
They do not. `lib/capability/bob_capability.ml` compiles, and a repo-wide grep
finds no reference to `Bob_capability` from any code — not cognition, not the
replay driver, not one test. It is linked and unused. Deleting the file would
change no behaviour.

SPEC §1.2 asks for the opposite: *"Prefer explicit module injection / higher-order
construction over global singletons."* Effects are a global singleton by nature.
The capability layer was meant to be the counterweight.

## What was verified before writing this

Every mechanism below was checked by compiling and running it, not reasoned
about. Probes were thrown away; the results are what matters.

| Claim | Result |
|---|---|
| Functor over a capability signature, effects still reach the handler | works |
| Functor alone denies body access | **NO — attack compiled and moved Bob** |
| Same attack with `(implicit_transitive_deps false)` | `Unbound module "Bob_effect"` |
| Cost of that flag project-wide | 4 errors, all `Unbound module Eio`, all in `test/` |
| Three-layer domain/effect/capability stack builds | works |
| Cognition parameterised over capabilities cannot name the ops library | `Unbound module "E"` |
| Cognition declaring and performing its OWN effect | **compiles — see Limits** |
| That self-declared effect reaching a handler | `Effect.Unhandled`, 0 actions recorded |
| `with-accepted-exit-codes (not 0)` compile-fail rule, leak closed | dune exit 0 (passes) |
| Same rule when the leak is reopened | dune exit 1 (fails) |

The second row is the finding that shaped this design. A functor by itself is
decoration: because `bob_effect` is reachable through the dune dependency
graph, `Bob_effect.Body.look_at` stays nameable no matter what the capability
signature omits. The flag is the load-bearing half, not the functor.

## Architecture

Three libraries, with dune's dependency arrows doing the enforcing.

```
bob_domain        Types only. Memory.query/item, Brain.request/chunk/response,
    ^             Speech.chunk/stream, Body.target, Identity.request/result,
    |             every error type, and error_to_string.
    |             Depends on: bob_types, eio.
    |
bob_effect        The six Effect.t constructors and the six perform wrappers.
    ^             Nothing else. THE RESTRICTED LIBRARY.
    |             Depends on: bob_domain.
    |
bob_capability    Authority signatures and the implementations that forward
                  to the wrappers.
                  Depends on: bob_domain, bob_effect.

bob_cognition     Make (C : CONVERSATION_CAPABILITIES)
bob_trace         Make (C : CONVERSATION_CAPABILITIES)
                  Depend on: bob_domain, bob_capability. NOT bob_effect.

handlers          bob_handler_sim, bob_handler_replay, bob_handler_live,
                  bob_runtime. These depend on bob_effect and must: they
                  pattern-match the constructors to interpret them.
```

`dune-project` gains `(implicit_transitive_deps false)`. Without it the whole
design is theatre.

The asymmetry is the point. Handlers *interpret* effects and need the
constructors. Cognition *requests* capabilities and needs only the types plus
whatever its signature grants. The libraries make that distinction structural
rather than a naming convention.

### Why types and operations must separate

Cognition uses `Bob_effect` for two different things today: operations
(`recall`, `think`, `say`, `now`) and types (`Memory.query`, `Brain.Text`,
`Speech.Say`). A functor can hide the operations, but the types must stay
visible or cognition cannot name its own arguments. Since both currently live
in the same module — `Bob_effect.Memory` holds `query` and `recall` — hiding
one hides the other. Hence `bob_domain`.

## What is being changed

**New:** `lib/domain/bob_domain.ml` and its dune file. The type modules move
here verbatim, keeping their current shapes, including C4's
`Brain.chunk = Text of string | Failed of error`.

**Reduced:** `lib/effect/bob_effect.ml` keeps the six `type _ Effect.t +=`
declarations, the six wrappers, and `name_of`. Its type modules are deleted in
favour of `bob_domain`. `name_of` stays because the tracing handler needs it
and tracing is handler-side.

**Functorised:** `lib/cognition/bob_cognition.ml` and `lib/trace/bob_trace.ml`
become `Make (C : Bob_capability.CONVERSATION_CAPABILITIES)`. Their dune
stanzas drop `bob_effect`. `Memory_policy` stays a plain module — it is pure
and performs nothing.

**Extended:** `CONVERSATION_CAPABILITIES` gains `now` and `look_at` is
deliberately excluded. A second signature, `CONVERSATION_WITHOUT_BODY`, is the
denial case the tests exercise.

**Unchanged:** every handler, `bob_runtime`, and all the frozen Phase 0
reducers — `world`, `workspace`, `control`, `project`, `memory`, `obs`,
`types`, `events`. Patch 002 criterion 1 continues to hold.

**Untouched by design:** `PERCEPTION_CAPABILITIES` and `BODY_CAPABILITIES`
keep their signatures but acquire no consumers, because no vision worker or
OpenRB driver exists yet. They are documented as awaiting consumers rather
than described as gating anything.

## Testing

Three kinds, in order of what they protect.

**1. Nothing breaks.** All 138 existing tests stay green, and `bob-replay`
produces byte-identical output against the baseline captured before Patch 002
began (`md5 b27696598fdc61b8c5b5bb5737879aa4`). `bob_trace` is the migration
risk; this is the check that catches it. A diff is a bug in the migration,
never a reason to update the expectation.

**2. The positive case.** A cognition instantiated with
`CONVERSATION_WITHOUT_BODY` still recalls, thinks and speaks — denial removes
the body, not the conversation.

**3. The denial itself, as a compile-fail test.** A module that names
`Bob_effect.Body.look_at` while depending only on `bob_domain` and
`bob_capability` must FAIL to compile. Expressed as a dune rule:

```
(rule
 (alias runtest)
 (deps leak.ml)
 (action
  (with-accepted-exit-codes (not 0)
   (run ocamlfind ocamlopt -c %{deps} -o leak.cmx))))
```

Verified in both directions: passes when the leak is closed, fails when it is
reopened. This is the test that stops someone restoring `bob_effect` to
cognition's dune stanza to fix an unrelated error.

## Limits — what this does NOT guarantee

A module can declare its own effect and perform it:

```ocaml
type _ Effect.t += Sneaky : Body.target -> unit Effect.t
let go () = Effect.perform (Sneaky Neutral)
```

This compiles. OCaml effects are not statically tracked and nothing prevents a
module inventing one. What saves the design is that a self-declared effect
reaches no handler: it raises `Effect.Unhandled` rather than moving anything.
Measured — performing a `Sneaky` effect inside a fully installed sim handler
stack raised `Effect.Unhandled` and the handler recorded zero actions.

So the guarantee is precisely: **cognition cannot reach Bob's body through
Bob's own effect vocabulary, and any attempt to route around it fails loudly
at runtime rather than silently succeeding.**

That is a real guarantee. It is not "cognition cannot perform effects," and
the definition of done must not be written as though it were.

Two further limits worth stating:

- The denial is compile-time and per-library. It constrains what a *module*
  may name, not what a *fiber* may do at runtime.
- `(implicit_transitive_deps false)` makes every dependency explicit
  project-wide. That is a real benefit, but it means a new library with a
  missing dep now fails to build where it previously worked by accident.

## Definition of done

- [ ] `bob_domain` exists; `bob_effect` holds only constructors, wrappers and
      `name_of`.
- [ ] `dune-project` sets `(implicit_transitive_deps false)`; the whole tree
      builds.
- [ ] `bob_cognition` and `bob_trace` are functors and neither dune stanza
      names `bob_effect`.
- [ ] A repo-wide grep shows `Bob_capability` referenced from real code, not
      only from its own file.
- [ ] The compile-fail test passes, and has been shown to fail when the leak
      is deliberately reopened.
- [ ] All 138 pre-existing tests green.
- [ ] `bob-replay` byte-identical to the baseline.
- [ ] Patch 002 criterion 11 updated: ticked for conversation, with the
      Limits section's wording, and explicit that perception and body
      actuation still await consumers.
