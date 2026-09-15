# Bob

A small stationary desktop robot with an expressive pan/tilt head, display
eyes, camera, microphone array and speaker. Warm, curious, gently deadpan.
Speaks Swedish and English.

> Bob is not an LLM with sensors. Bob is a collection of perception, memory,
> attention, control, cognition and action systems. The LLM is one subsystem.

See [SPEC.md](SPEC.md) for the authoritative design.

## Status

**Phase 0 — not yet started.** No hardware ordered. No code written.

All physical capability claims are **PENDING** until measured on real
hardware. A simulation never verifies a physical capability.

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
