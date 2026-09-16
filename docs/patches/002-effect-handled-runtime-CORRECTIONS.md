# Patch 002 — corrections

Errors found in Patch 002 as written, each verified by compiling and running
the case on this machine (OCaml 5.4.1, Eio 1.5). The patch is implementable;
these are the places where it is factually wrong or underspecified.

## C1. Effect handlers do NOT cross `Eio.Fiber.fork` — BLOCKING

**The patch assumes** (§7, §12) that you install a handler environment and run
cognition beneath it, with §12's eight concurrent loops performing domain
effects inside it.

**Reality:** a `perform` inside a forked fiber does not reach a handler
installed outside the switch. Eio fibers are themselves built on effects;
forking installs Eio's own handler, and an unknown effect unwinds to it and
is re-raised as `Effect.Unhandled`.

Measured:

| Case | Result |
|---|---|
| Handler outside, no fork | OK |
| **Handler outside, perform inside `Fiber.fork`** | **`Effect.Unhandled`** |
| **Handler outside, perform inside `Fiber.both`** | **`Effect.Unhandled`** |
| **Handler outside, perform inside `Fiber.first`** | **`Effect.Unhandled`** |
| `Fiber.yield` under a handler | OK (creates no fiber) |
| Handler installed inside each fiber | OK |
| `Fiber.both` with a handler inside each branch | OK |
| Eio sleep inside our handler | OK |
| Eio timeout inside our handler | OK (cancels correctly) |
| Handler body performs Eio IO while servicing | OK |

**The rule is broader than `fork`.** *Any* Eio operation that spawns a fiber
breaks the handler chain — `fork`, `both` and `first` all do. Only `yield`
survives, because it creates no fiber.

**Correction:** every fiber installs its own handler stack. Provide one spawn
helper and require all fiber-spawning to go through it:

```ocaml
val Bob_runtime.fork : sw:Eio.Switch.t -> sim:... -> (unit -> unit) -> unit
(* forks a fiber that has ALREADY had the handler stack installed *)
```

A bare `Eio.Fiber.fork`, `Fiber.both` or `Fiber.first` in cognitive code is a
bug. Worth a test.

Two patterns work for a producer/consumer stream inside cognition, both
verified:

- **Fill then perform.** When the producer is local and finite, fill the
  stream and then perform the effect. No fiber is spawned at all. The stream's
  capacity must exceed the item count or `Stream.add` blocks forever with no
  consumer. Prefer this.
- **Handler in each branch.** `Fiber.both (fun () -> with_handlers a)
  (fun () -> with_handlers b)` works, at the cost of naming the handler stack
  at each branch.

## C2. §18 references a "Patch 001" and `bob-edge` that do not exist

Patch 002 §18 says the edge reflex path was "introduced in Patch 001", and
§7/§11/§24 name a `bob-edge` component. Neither exists in this repository:
`bob-edge` appears nowhere in SPEC.md or the code, and there is no Patch 001
document.

SPEC.md §3 and §26 specify the NUC talking to an **OpenRB-150** body
controller over USB serial, with that controller owning low-level motion
interpolation and hardware safety.

**Correction, pending Patch 001:** read `bob-edge` as the OpenRB-150 body
controller. §18's reflex exception then means the VAD/DoA reflex loop runs on
that controller rather than the NUC, which is consistent with both documents.
§24's `body_edge.ml` is kept as the handler name. **Revisit if Patch 001
turns out to describe a separate edge process.**

## C3. §3's effect type syntax will not compile as written

The patch shows one `type _ Effect.t +=` block with several constructors
separated by blank lines. OCaml requires each extension constructor in a
single extension declaration, or separate `+=` declarations. More importantly
the GADT return types must be written on the constructor.

**Correction:** the working form is

```ocaml
type _ Effect.t += Now : Time.t Effect.t
type _ Effect.t += Recall : Memory.query -> Memory.item list Effect.t
type _ Effect.t += Think : Brain.request -> Brain.response Effect.t
```

Verified to compile and run.

## C4. §10 and §19 conflict: a stream cannot also be a result-typed error

§10 wants `Brain.response = Brain.chunk Stream.t`. §19 wants typed domain
errors such as `Timeout | Unavailable | Rate_limited`. A stream that has
already been returned cannot then fail with a typed error at the effect
boundary — the failure happens mid-stream, after `Think` has returned.

**Correction:** put the error in the stream, not around it.

```ocaml
type Brain.chunk = Text of string | Failed of Brain.error
type Brain.response = Brain.chunk Eio.Stream.t
```

`Think` returns the stream immediately; a provider failure arrives as a
`Failed` chunk. Consumers must handle a `Failed` chunk at any position,
including first. The alternative — `(response, error) result` around a stream
— only reports failures that occur before the first chunk, which is the
minority of real failures.

## C5. §20's "every performed domain effect must be traceable" needs a
     mechanism the patch does not give

Observability cannot live in each handler without duplicating it six times,
and §25 forbids building a middleware framework.

**Correction:** a single tracing handler that records start/end/outcome and
re-performs. ~30 lines, not a framework.

**The nesting is counter-intuitive and easy to get backwards.** A `perform`
inside a handler escapes *outward* to the enclosing handler, so the
interpreting handler must be OUTSIDE and tracing INSIDE:

```ocaml
with_sim (fun () -> with_tracing clock (fun () -> cognition ()))   (* captures *)
with_tracing clock (fun () -> with_sim (fun () -> cognition ()))   (* captures NOTHING *)
```

Measured: the first arrangement logs `Now` and `Think`; the second logs
nothing **and does not error** — the program produces the right answer with
silently empty traces. Wrapping the stack the intuitive way round is a silent
failure, so this needs a test asserting the trace is non-empty.

## C6. Acceptance criterion 6 cannot be met by this patch alone

Criterion 6 is "the same cognitive flow runs under live and fake handlers."
**No live handler can exist yet**: there is no OpenRouter key configured, no
TTS, no OpenRB hardware, and no vision worker. Building `brain_openrouter.ml`
is possible; *running* it is not verifiable here.

**Correction:** criterion 6 splits into

- 6a. The cognitive flow runs under sim and replay handlers. **Testable now.**
- 6b. The same flow runs under live handlers. **PENDING** until credentials
  and hardware exist. Do not claim it on the basis of a compiling handler.

## C7. §14 forbids `Unix.gettimeofday` but Phase 0 already uses `mtime`

Not an error in the patch, a note: Phase 0's `Bob_types.Time` is a plain float
with an explicit `~now` parameter threaded through every accessor, which
already satisfies §2 and §14's intent. Converting it to a `Now` effect is
optional and arguably a regression for the pure reducers, which §2 and §26
say must take their data explicitly.

**Correction:** apply the `Now` effect to *cognition and handlers*, not to the
pure reducers. `World.apply`, `Workspace.apply` and `Control.decide` keep
their explicit `~now` parameters. This is what §2 and §26 already require;
spelling it out prevents an implementer from "helpfully" converting them.

## Verification

Every claim above was checked by compiling and running the case, not reasoned
about. The probe covered: handler/fiber interaction (7 cases), streaming
first-chunk timing, mid-stream cancellation, the corrected effect-declaration
syntax, and a mid-stream typed failure.

## What the patch gets right (verified)

- §10 streaming genuinely works through an effect: a handler that forks a
  producer fiber and returns an `Eio.Stream.t` lets the consumer start before
  generation finishes. Measured first-chunk at 10 ms with a 60 ms total.
- §13 cancellation propagates: an `Eio.Time.with_timeout_exn` around a
  blocking effect cancels mid-stream correctly.
- A handler body may perform Eio IO while servicing an effect, so live
  handlers can do real network calls.

## C8. Effect handler bodies that block must use `discontinue` — BLOCKING

Found during Task 8, root-caused and fixed there.

The sim `Speak` handler blocks inside the handler body itself
(`Eio.Stream.take`, and `pace`'s `Eio.Time.sleep`) rather than inside the
resumed continuation. When Eio cancels one of those blocking calls, letting
the exception propagate normally unwinds `Effect.Deep.match_with` directly
and **bypasses the continuation `k`**. The caller's own `try ... with
Eio.Time.Timeout` sits downstream of the `Effect.perform` call — that is,
inside `k` — so it never runs. The exception escapes the whole test as
`Cancelled: Eio__Time.Timeout`.

**Correction:** deliver the exception into the continuation with
`Effect.Deep.discontinue k exn`, which re-raises at the perform site where
the caller's handler is waiting:

```ocaml
match drain () with
| () -> commit (); continue k (Ok ())
| exception exn -> commit (); discontinue k exn
```

`commit ()` runs on both paths so a cancelled utterance still records what
was actually spoken.

Verified by reverting the fix: `barge-in stops speech` fails with
`[exception] Cancelled: Eio__Time.Timeout`. With the fix, all three
cancellation tests pass.

**The rule:** any handler body that blocks before calling `continue` must
route exceptions through `discontinue`. `Think` is not affected because its
blocking work happens in a forked producer fiber and the consumer's
`Stream.take` runs in the caller's own continuation — but this asymmetry is
easy to break if `Think`'s handler is ever changed to block synchronously.

## C9. Two diagnostic regressions from the Task 7 migration — ACCEPTED

Recorded rather than fixed; neither affects `bob-replay`'s default output,
which is byte-identical across the migration.

1. **`-v` no longer prints the projected context.** The old CLI read
   `last_request` from the fake brain capability. `Bob_handler_sim` has no
   equivalent accessor. `-v` still prints the EVENTS block. Restoring this
   needs a `last_request` accessor on the sim handler.

2. **The SPEECH section no longer reports "(interrupted N time(s))".** The
   count came from the fake TTS capability's stop counter. `Interrupt_speech`
   is now a decision record with no effect call, so there is no counter to
   read. Task 8 establishes cancellation at the effect level; wiring
   `Interrupt_speech` to actually cancel a speech fiber is future work.

3. **`Body.target` carries no pitch.** `Bearing of Angle.t` is yaw-only, so
   a brain-proposed `Look_at` with non-zero pitch would have that pitch
   silently dropped. Not currently reachable: `Control.decide`'s reflex path
   hardcodes `pitch = 0.`. Adding pitch to the vocabulary is the fix if a
   cognitive path ever proposes one.
