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
| **Handler outside, perform inside forked fiber** | **`Effect.Unhandled`** |
| Handler installed inside each fiber | OK |
| `Fiber.both`, handler inside each branch | OK |
| Eio sleep inside our handler | OK |
| Eio timeout inside our handler | OK (cancels correctly) |
| Handler body performs Eio IO while servicing | OK |

**Correction:** every fiber must install its own handler stack. Provide one
spawn helper and require all forks to go through it:

```ocaml
val Bob_runtime.fork : sw:Eio.Switch.t -> env:Handlers.t -> (unit -> unit) -> unit
(* forks a fiber that has ALREADY had the handler stack installed *)
```

A bare `Eio.Fiber.fork` in cognitive code is a bug. This is worth a test.

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

**Correction:** a single tracing handler installed outermost in the stack,
which records start/end/outcome and re-performs. This is ~30 lines, not a
framework. Note it must be *outermost* so it sees effects before the
interpreting handler consumes them.

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
