# Bob

A small stationary desktop robot with an expressive pan/tilt head, display
eyes, camera, microphone array and speaker. Warm, curious, gently deadpan.
Speaks Swedish and English.

> Bob is not an LLM with sensors. Bob is a collection of perception, memory,
> attention, control, cognition and action systems. The LLM is one subsystem.

See [SPEC.md](SPEC.md) for the authoritative design.

## Status

**Phase 0 complete.** Cognitive core built and tested on fakes. 101 tests
across 12 suites. No hardware ordered; no hardware code written.

Try it:

```bash
opam switch link default     # once per working directory
opam exec -- dune test
opam exec -- dune exec bin/bob_replay.exe -- test/fixtures/screwdriver.trace -v
```

The replay drives the real world reducer, workspace, controller, context
projector and a fake brain from a recorded event trace. Bob's orientation
decision fires at t=0.000s, 1.68 seconds before the utterance is final.

### What Phase 0 does NOT establish

All physical capability claims are **PENDING** until measured on real
hardware. A simulation never verifies a physical capability.

- No latency claim about real hardware. Every number in the replay report is
  trace-derived — it is the timestamp the fixture asserts, not a measurement.
- No claim that whisper, SCRFD or CVLFace run fast enough on the target NUC.
  See [bench/README.md](bench/README.md) for what must be measured there.
- No claim about recognition accuracy, Swedish or English quality, or
  discriminating between siblings.
- Nothing moved. No audio was captured or played. No model was called.

- [Spec deltas and verified findings](docs/2026-09-15-spec-deltas-and-findings.md)

## Layout

    bin/        entry points
    lib/        OCaml cognitive core
    test/       property and trace-replay tests
    prompts/    personality and system prompts (editable, not compiled in)
    firmware/   OpenRB-150 body controller (Phase 1)
    cad/        enclosure (later)
    docs/       design notes, findings, runbooks

Runtime state lives in `bob-data/`, outside version control.

## Checks

### Capability boundary

`./test/deny/check-leak.sh` asserts that a conversation-granted subsystem
cannot name `Bob_effect`. It is not part of `dune test`: the probe must fail
to compile, and a nested `dune` inside a dune rule cannot take the build lock.
Run it directly, and in CI alongside `dune test`.
