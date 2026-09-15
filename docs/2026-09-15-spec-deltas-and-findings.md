# Spec deltas and verified findings — 2026-09-15

Companion to `SPEC.md`. `SPEC.md` is authoritative; this records what changed
from the original handover and what was actually verified in session.

## 1. Deltas from the original handover

The handover ("Bob — implementation handover for Pi/Claude") is superseded.
Material changes:

| Area | Handover | SPEC.md v1 |
|---|---|---|
| Architecture | Sequential composed pipeline | Concurrent loops; perception → world → workspace → control → brain (§33) |
| Body controller | ESP32-S3 (XIAO Sense), ESP-IDF in C | OpenRB-150, Dynamixel XL330 (§3) |
| Audio in | ESP32 onboard mic | reSpeaker Flex XVF3800 Circular-4, USB (§3) |
| STT | Cloud / OpenRouter | Local whisper.cpp, OpenRouter as replaceable alternative (§11) |
| TTS | OpenRouter `/audio/speech` | Local Piper (§23) |
| LLM role | Agentic harness driving tools | One subsystem; proposes actions, controller validates (§22, §33) |
| Memory | Per-person `memory.md` only | Episodic SQLite+FTS **and** compact semantic `profile.md` (§19) |
| Attention | Not addressed | First-class; DoA-driven reflex orientation (§10, §16) |
| Latency | Not addressed | Architectural property with explicit classes (§17) |
| Sim device | Simulated webcam/mic CLI adapter | Event replay harness driving real reducers (§27) |

Still-relevant handover material carried into SPEC.md or retained as guidance:
privacy policies, conversational enrolment flow, personality direction,
"never claim a simulation verified a physical capability".

## 2. Verified in session (2026-09-15)

Checked on the dev machine, not assumed:

- **SQLite 3.53.4 with FTS5 working** — verified by creating an FTS5 table and
  matching. §19C episodic search is unblocked.
- **OCaml 5.2.0+ox**, dune 3.23. Installed: `sqlite3` 5.4.2, `yojson`, `mtime`
  2.2.0 (monotonic timestamps for §28), `alcotest`, `qcheck`, `cmdliner`,
  `logs`, `base64`, `uri`, `cohttp`.
- **Not yet installed but available in the switch**: `eio`/`eio_main` (1.5),
  `caqti`, `ppx_yojson_conv`, `bos`, `domainslib`.
- `ffmpeg`/`ffprobe` present. `uv` present, Python 3.14.7.
- **No Bob hardware attached** — `lsusb` shows no camera, reSpeaker or OpenRB.
- `whisper.cpp` and `piper` not installed.

## 3. Hardware findings

### 3.1 Target NUC has no NPU — and "99 TOPS" does not apply to it

ASUS NUC 15 Pro barebone, **Intel Core 3 100U**, 16 GB RAM, 1 TB.

**The "99 TOPS" marketing figure is not a spec of this machine.** It is a
*platform aggregate* (CPU + GPU + NPU summed) for the top of the NUC 15 Pro
family — the NUC 15 Pro+ with a Core Ultra 9 285H, which has an Arc GPU and a
real NPU. Two reasons it does not transfer:

1. It describes the family ceiling, not this configuration.
2. The Core 3 100U is **Raptor Lake, launched Q1'24** — previous generation,
   not Core Ultra Series 2. The NUC 15 Pro line spans both; this is the
   budget end.

**No usable NPU.** Intel's spec lists "Intel Gaussian & Neural Accelerator
(GNA) 3.0", which is *not* an NPU in the modern sense — it is a tiny
low-power block for noise suppression and wake-word class work, measured in
fractions of a TOP. It cannot run whisper or a ViT. Intel AI Boost / NPU
branding is absent, and "Intel Deep Learning Boost on GPU: **No**".

**An NPU cannot be added.** NPUs are on-die. USB/M.2 accelerators (Coral,
Hailo-8) run fixed pre-compiled models; whisper and CVLFace ViT realistically
will not port, and the M.2 slot holds the SSD. Not pursued.

Specifications:

- 6 cores / 8 threads (2 P + 4 E), up to 4.7 GHz, 10 MB L3
- **15 W TDP**
- **Intel Graphics, 64 EUs @ 1.25 GHz** (see §3.2 — this is the real
  accelerator available)
- Quick Sync: H.264/H.265 hardware encode/decode, AV1 decode
- 2x DDR5 SO-DIMM (up to 96 GB), 4x USB-A + 1x USB-C, 2x Thunderbolt 4,
  2.5 GbE

Sources:
- <https://www.intel.com/content/www/us/en/products/sku/236776/intel-core-3-processor-100u-10m-cache-up-to-4-70-ghz/specifications.html>
- <https://www.inet.se/produkt/2226965/asus-nuc-15-pro-barebone-i3-100u-slim>
- <https://www.asus.com/us/displays-desktops/nucs/nuc-mini-pcs/asus-nuc-15-pro/techspec/>

USB port count is sufficient: reSpeaker + camera + OpenRB = 3 devices.

### 3.2 The iGPU is the accelerator to use

The 64-EU iGPU is **otherwise unused** — the owner runs nothing on it. It is
the correct offload target, and its strategic value is as much about
**freeing CPU cores shared with co-tenants (§3.6)** as about raw throughput.

- **whisper.cpp supports OpenVINO** for encoder inference on Intel iGPU.
  This is the largest single win available, since whisper is the latency
  risk.
- **SCRFD via OpenVINO** on the iGPU is well-trodden.
- **Quick Sync** gives hardware video decode, so the camera stream costs
  almost no CPU.

Caveats, stated honestly: 64 Raptor Lake EUs is modest — far below an Arc
140T, and far below the dev box's RTX 2070. It will not make large-v3-turbo
trivially fast. OpenVINO on Linux needs compute-runtime packages installed.
This moves the §17 budget from "probably misses" to "plausibly meets,
measure it".

No architectural change: §1.2 already makes STT swappable, so this is
configuration, not redesign.

### 3.3 Latency risk — OPEN

§17 targets <1 s from end-of-utterance to first audio. Phase 2+ concurrent
load on a 15 W part with no NPU:

- whisper large-v3-turbo-q5_0 streaming (~800 MB)
- SCRFD at 5–10 Hz
- CVLFace ViT-Base occasionally
- Piper TTS streaming
- bob-core

**whisper is the primary risk.** Mitigations already permitted by the spec,
in order of preference:

1. **OpenVINO on the 64-EU iGPU** (§3.2) — likely the answer; also frees CPU
   for co-tenants.
2. Smaller or distilled whisper model (Swedish accuracy cost).
3. OpenRouter STT (§11 keeps it swappable via §1.2).

Resolve by measurement (§28), not assumption. The Phase 0 benchmark harness
must compare: whisper CPU across model sizes; whisper OpenVINO on iGPU;
SCRFD CPU vs OpenVINO; and **all of it concurrent under realistic co-tenant
load** — the last being the only number that actually matters.

### 3.4 Dev machine ≠ target

Dev box: Ryzen 5 2600X (6c/12t), 32 GB, **RTX 2070 8 GB**.

This comfortably runs the full ML stack, which the NUC may not. **Do not let
GPU-accelerated dev performance validate a NUC latency claim.** Every §17
measurement must be reproduced on the NUC before it is treated as met.

Split-host deployment (workers on the desktop, bob-core on the NUC) is
possible — §25 puts workers behind capability interfaces, so it is a transport
change. But it adds a network hop to the reflex path (§17), conflicting with
"start boring / Unix-domain sockets". **Extension point, not a v1 assumption.**

### 3.5 Nothing ordered yet

No hardware purchased. §3 choices are candidates pending a BOM verification
pass: exact reSpeaker Flex variant and FPC length, camera FOV/low-light, XL330
horn/bracket fit, OpenRB power budget, and the §4 microphone power-domain cut
for a genuine hardware mute.

### 3.6 NUC is a shared host

The NUC also runs the owner's other personal apps — not constantly, and not
resource intensive, but Bob cannot assume the whole 15 W / 6-core budget.

Consequences:

- **Benchmark under realistic load**, not on an idle NUC. A whisper timing
  taken on a quiet box overstates what Bob actually gets.
- **Bob must be a well-behaved tenant.** Bound worker CPU (cgroup or `nice`)
  so Bob cannot starve the owner's other apps.
- The §17 background class (consolidation, episode summarization, gallery
  maintenance) must be explicitly deprioritized — it already must never block
  a faster class, and on a shared host it must not compete with co-tenants
  either.
- Headroom is a first-class constraint: if the latency budget only closes on
  an idle NUC, it does not close.

## 4. Other findings

**Python version.** SCRFD/CVLFace need PyTorch or ONNX Runtime; wheels
routinely lag new CPython. System Python is 3.14.7. Pin the vision worker to a
Python with confirmed wheels via `uv`; do not inherit the system interpreter.

**§32 "no vector database" does not conflict with §6.** With a bounded gallery
(~32 embeddings/person, §9) and a handful of people, brute-force cosine
similarity over a few hundred 512-D vectors is microseconds. No index is
needed. Recorded so this is not later "fixed" by adding FAISS.

## 5. Decisions taken in session

- Repo at `vibe/bob/`, jj, master branch.
- `SPEC.md` canonical; this file records deltas and findings.
- Phase 0 covers the full loop on fakes, plus a benchmark harness so model
  selection is evidence-based before Phase 2.
