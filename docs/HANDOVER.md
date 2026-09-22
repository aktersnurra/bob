# Bob — handover

Written 2026-09-23. Everything below was verified by running it, not recalled.

## Paste this to start the next session

> I'm continuing work on Bob, a small stationary desktop robot with an
> expressive pan/tilt head, display eyes, camera, mic array and speaker. Warm,
> curious, gently deadpan, child-friendly, Swedish + English.
>
> Work in the jj workspace at
> `/home/aktersnurra/projects/vibe/bob.workspaces/phase0`. Read `SPEC.md`
> (authoritative), then `docs/HANDOVER.md` for state and open work. Don't
> re-derive what the handover already records.
>
> Phase 0 and Patch 002 are complete. Criteria 6b and 10 are open and both
> block on the same missing piece: `lib/handler_live/` has no transport.
>
> Next task: <pick one from "What to do next">.

## State

- Repo: https://github.com/aktersnurra/bob — **public**, default branch `master`
- Workspace: `bob.workspaces/phase0`, clean, in sync with `origin/master` at `f722fa82`
- Toolchain: OCaml **5.4.1 stock `default` switch** (NOT `5.2.0+ox` OxCaml), dune 3.24, Eio 1.5
- Build clean, **142 tests / 20 suites**, `dune test` exit 0
- `./test/deny/check-leak.sh` exit 0
- `bob-replay` output md5 `b27696598fdc61b8c5b5bb5737879aa4` — byte-identical since before Patch 002. **Treat any change as a regression until proven intentional.**

Verify all of it in one go:

```bash
cd /home/aktersnurra/projects/vibe/bob.workspaces/phase0
opam exec -- dune build && opam exec -- dune test && ./test/deny/check-leak.sh
opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace | md5sum
```

## Architecture in one paragraph

Six domain effects (`now`, `recall`, `think`, `say`, `look_at`, `identify`) are
OCaml 5 effects declared in `lib/effect/`, with swappable handlers: `handler_sim`
(deterministic, records actions), `handler_replay` (recorded results), and
`handler_live` (**compile-only by choice** — builds requests, parses SSE, has no
transport). Pure reducers (`World.apply`, `Workspace.apply`, `Control.decide`)
keep explicit `~now` parameters and perform no effects. Subsystems take their
authority as a module parameter: `bob_cognition` is a functor over
`CONVERSATION_CAPABILITIES`, `bob_trace` over `EMBODIED_CAPABILITIES`.

## The corrections file is the most valuable document here

`docs/patches/002-effect-handled-runtime-CORRECTIONS.md` — ten findings (C1–C10),
each verified by compiling and running the case. Read it before touching effects
or handlers. Three will bite you:

- **C1** — effect handlers do NOT cross *any* fiber spawn. `fork`, `both`,
  `first` all break the chain; only `yield` survives. Use `Bob_runtime.fork`,
  which installs the handler stack per fiber. Prefer "fill-then-perform".
- **C5** — the tracing handler nests **inside** the interpreting handler. The
  intuitive order captures nothing **and does not error**. Silent failure.
- **C8** — a handler body that blocks before calling `continue` must deliver
  exceptions via `discontinue k exn`, or Eio cancellation unwinds `match_with`
  directly and escapes the caller's `try/with`. This will matter the moment a
  live transport blocks on a socket.

## What to do next

### 1. OpenRouter transport — recommended, unblocked

Closes criteria 6b and 10 together. Needs an API key and a network connection,
no hardware. Write the transport into `lib/handler_live/`; everything around it
(config, request construction, `error_of_status`, `parse_sse_line`) already
exists and is tested.

Two things to get right. **C8 is the real test here** — a socket read is a
genuinely blocking handler body, where the sim's blocking was written to be
verifiable. And **do not tick 6b whole**: with no TTS and no OpenRB, "the same
flow runs under live handlers" is true for `Think` and false for `Speak` and
`Look_at`. Split it into 6b-brain and 6b-embodied, the way 6 was split into
6a/6b.

Side benefit: measuring real first-token latency tells you how much of SPEC §17's
budget is left for local ASR before the NUC is ever set up.

### 2. CI — small, and now public-facing

Nothing enforces the capability boundary automatically. `check-leak.sh` cannot
live inside `dune test` (the probe must fail to compile, and a nested `dune`
can't take the build lock), so it needs its own CI step **alongside** `dune test`.
A reader of a public repo checks this first.

### 3. Stale default workspace — one command

`../../bob` sits on empty commit `ac70b5b6`, a sibling of the real history
branched off the early OxCaml-switch fix. Nothing is lost; it just looks empty.
Fix with `jj workspace update-stale` or by pointing it at `master`.

## Blocked or deferred — do not restart unprompted

- **NUC benchmark** — `bench/setup-nuc.sh` → `record-fixtures.sh` →
  `run-bench.sh --load`. The only thing that can validate SPEC §17's latency
  budget. Blocked on physical access; the user explicitly declined ("I will not
  do that mess now"). **Ask before starting.**
- **C2** — Patch 002 §18 references a "Patch 001" and a `bob-edge` component
  that exist nowhere in the repo. Currently read as the OpenRB-150 body
  controller. Only the user can settle it.
- **C9** — three accepted diagnostic regressions: `-v` no longer prints
  projected context; SPEECH lost "(interrupted N times)"; `Body.target` is
  yaw-only. Recorded, not bugs to fix blind.
- **Perception gating** — `PERCEPTION_CAPABILITIES` gates nothing until a vision
  worker exists (Phase 3). The code says so explicitly; don't claim otherwise.

## Two honesty rules this project runs on

**Don't tick a criterion you haven't attacked.** Criterion 11 was once claimed
while `bob_capability` was referenced by no code at all. It is now met because
the attack was inserted into the real `bob_cognition.ml` and `bob_trace.ml` and
both gave `Unbound module Bob_effect` — not because the build was clean.

**A guard nobody has watched fail isn't known to work.** The leak guard was
confirmed by reopening the leak and observing exit 1, then closing it and
observing exit 0. Same for criterion 8's `validate` guard, proven load-bearing
by mutation twice.

Enforcement has two halves and both are load-bearing: the capability signature
omits the denied operation, **and** `dune-project` sets
`(implicit_transitive_deps false)`. Without the flag the functor denies nothing —
measured, the attack compiled and moved Bob (C10).

## Note on the public repo

`gustaf`, `olle` and `knut` appear as test data in `SPEC.md`, `prompts/` and
~12 tests, and the repo is public with the author's email on every commit. The
user chose this knowingly on 2026-09-23. Don't re-raise it; changing it now
would mean rewriting all 46 commits, and forks would keep the old hashes.
