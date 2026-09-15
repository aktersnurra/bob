# Bob benchmark harness

**Status: specification only. Nothing here has been run.**

The NUC is not yet purchased. These numbers decide whisper model selection
and whether SPEC section 17's budget is reachable, so they must be measured
on the real target under realistic load — not on the dev box, which has an
RTX 2070 and would flatter every result.

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
