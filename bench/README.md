# Bob benchmark harness

**Status: scripts written and dry-run tested. No real measurement taken.**

These numbers decide whisper model selection and whether SPEC section 17's
budget is reachable, so they must be measured on the target NUC under
realistic load — not on the dev box, whose RTX 2070 would flatter every
result. `run-bench.sh` prints a warning in its own report if it detects an
NVIDIA GPU, for exactly this reason.

## Running it

On the **NUC**, from a checkout of this repo:

```bash
./bench/setup-nuc.sh              # whisper.cpp CPU + OpenVINO builds, models
./bench/record-fixtures.sh        # ten Swedish + ten English clips, your voice
./bench/run-bench.sh ~/bob-bench --load
```

`setup-nuc.sh` is idempotent and prints exact instructions if OpenVINO or the
Intel compute runtime are missing. `run-bench.sh` writes a timestamped
markdown report to `~/bob-bench/results/`.

`--load` adds a pass with busy loops on half the cores, standing in for your
other applications. **That is the pass that decides anything** — a model that
meets the budget on an idle box and misses it under load has not passed.

The fixtures are your own voice in your own room, with Swedish diacritics
intact, because word error rate on a public corpus says nothing about whether
Bob understands *you* at a desk.

## What to measure

| Configuration | Question it answers |
|---|---|
| whisper.cpp CPU, large-v3-turbo-q5_0 | Is the spec default viable at all? |
| whisper.cpp CPU, small and medium | How much accuracy must be traded? |
| whisper.cpp OpenVINO, iGPU | Does the 64-EU iGPU close the gap? |
| SCRFD CPU vs OpenVINO at 5-10 Hz | Can detection leave cores for whisper? |
| CVLFace ViT-Base, single inference | Is <=1 Hz recognition affordable? |
| All concurrent, under co-tenant load | **The only number that decides anything.** |

## How to measure

1. Install on the NUC: whisper.cpp with OpenVINO, OpenVINO runtime, Intel
   compute-runtime for the iGPU.
2. Record, with a real microphone, ten Swedish and ten English utterances of
   3-10 seconds. Keep them; they are the fixture set.
3. For each configuration, report: time to first partial, time from
   end-of-speech to final transcript, peak RSS, and mean CPU utilisation.
4. Repeat the concurrent run while the owner's usual applications are
   running. Report the same four numbers.
5. Record word error rate per language. A faster model that fails on Swedish
   is not faster.

## Pass criteria

Derived from SPEC section 17:

- end-of-speech to final transcript: **<500 ms**
- end-of-speech to first audio out (whole pipeline): **<1 s**
- reflex path (speech onset to movement command): **<100 ms** — this one is
  CPU-trivial and should pass comfortably; if it does not, something is
  structurally wrong.

If no configuration meets these under co-tenant load, the escalation order is:
smaller whisper model, then OpenRouter STT (SPEC section 11 keeps it
swappable), then move the whisper worker to the desktop and accept a network
hop in the perception path.

## What this harness does not do

It does not certify any physical capability. Latency measured with recorded
audio files is not latency measured with a live microphone, VAD segmentation
and a real speaker. Those numbers come in Phase 2.
