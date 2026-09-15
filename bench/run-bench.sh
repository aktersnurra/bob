#!/usr/bin/env bash
# Run the Bob STT benchmark and emit a filled-in results table.
#
# Measures, for each (model, backend) configuration:
#   - wall-clock transcription time per clip
#   - the ratio of that to clip duration (the real-time factor)
#   - peak resident memory
#   - word error rate against the recorded reference text
#
# The number that decides anything is the LAST one: everything running at once
# while your other applications are running. A model that is fast on an idle
# box and misses the budget under load has not passed.
#
# Usage:  ./bench/run-bench.sh [workdir] [--load]
#         workdir defaults to ~/bob-bench
#         --load  also runs a concurrent-load pass

set -euo pipefail

WORKDIR="${1:-$HOME/bob-bench}"
RUN_LOAD=0
[ "${2:-}" = "--load" ] && RUN_LOAD=1

WHISPER="$WORKDIR/whisper.cpp"
FIXTURES="$WORKDIR/fixtures"
RESULTS="$WORKDIR/results"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS/report-$STAMP.md"

mkdir -p "$RESULTS"

for t in ffprobe bc python3; do
  command -v "$t" >/dev/null 2>&1 || { echo "Required tool missing: $t" >&2; exit 1; }
done

# GNU time gives peak RSS. It is frequently absent on a fresh install, and
# without it we can still measure wall time, so degrade rather than fail --
# but say so, instead of silently reporting nothing.
GNU_TIME=""
for candidate in /usr/bin/time /bin/time; do
  [ -x "$candidate" ] && { GNU_TIME="$candidate"; break; }
done
if [ -z "$GNU_TIME" ]; then
  echo "NOTE: GNU time not found (install 'time'); peak RSS will be reported as n/a." >&2
fi

[ -d "$FIXTURES" ] || { echo "No fixtures at $FIXTURES. Run bench/record-fixtures.sh first." >&2; exit 1; }
ls "$FIXTURES"/*.wav >/dev/null 2>&1 || { echo "No .wav fixtures found in $FIXTURES" >&2; exit 1; }

# --- Machine identity, recorded in the report -----------------------------

CPU="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
CORES="$(nproc)"
MEM="$(awk '/MemTotal/ {printf "%.0f GB", $2/1024/1024}' /proc/meminfo)"
HAS_NVIDIA=no
lspci 2>/dev/null | grep -qi nvidia && HAS_NVIDIA=yes

# --- Helpers ---------------------------------------------------------------

# Word error rate: reference vs hypothesis, case- and punctuation-insensitive.
wer() {
  python3 - "$1" "$2" <<'PY'
import sys, re
def norm(s):
    s = s.lower()
    s = re.sub(r"[^\w\såäö]", " ", s)
    return s.split()
ref, hyp = norm(open(sys.argv[1]).read()), norm(open(sys.argv[2]).read())
if not ref:
    print("na"); raise SystemExit
# Levenshtein over words
d = [[0]*(len(hyp)+1) for _ in range(len(ref)+1)]
for i in range(len(ref)+1): d[i][0] = i
for j in range(len(hyp)+1): d[0][j] = j
for i in range(1, len(ref)+1):
    for j in range(1, len(hyp)+1):
        c = 0 if ref[i-1] == hyp[j-1] else 1
        d[i][j] = min(d[i-1][j]+1, d[i][j-1]+1, d[i-1][j-1]+c)
print(f"{100.0*d[len(ref)][len(hyp)]/len(ref):.1f}")
PY
}

clip_duration() {
  ffprobe -v error -show_entries format=duration -of csv=p=0 "$1" 2>/dev/null || echo 0
}

# Run one configuration over every fixture. Echoes a markdown table row.
run_config() {
  local label="$1" bin="$2" model="$3" extra="${4:-}"

  [ -x "$bin" ] || { echo "| $label | — | — | — | binary missing |"; return; }
  [ -f "$model" ] || { echo "| $label | — | — | — | model missing |"; return; }

  local total_wall=0 total_dur=0 peak_kb=0 n=0
  local wer_sum=0 wer_n=0
  local outdir="$RESULTS/$STAMP-${label// /_}"
  mkdir -p "$outdir"

  for wav in "$FIXTURES"/*.wav; do
    local base; base="$(basename "$wav" .wav)"
    local out="$outdir/$base"

    local wall kb
    if [ -n "$GNU_TIME" ]; then
      # %e is elapsed wall seconds, %M peak resident KB.
      local timing
      # shellcheck disable=SC2086  # $extra must word-split into separate args
      timing="$( { "$GNU_TIME" -f "%e %M" "$bin" \
          -m "$model" -f "$wav" -otxt -of "$out" -nt ${extra} \
          >/dev/null 2>/dev/null; } 2>&1 | tail -1 )" || true
      wall="$(echo "$timing" | awk '{print $1}')"
      kb="$(echo "$timing" | awk '{print $2}')"
    else
      local t0 t1
      t0="$(date +%s.%N)"
      # shellcheck disable=SC2086
      "$bin" -m "$model" -f "$wav" -otxt -of "$out" -nt ${extra} \
        >/dev/null 2>/dev/null || true
      t1="$(date +%s.%N)"
      wall="$(echo "$t1 - $t0" | bc -l)"
      kb=""
    fi

    # A non-numeric wall time means the run failed; skip rather than poison
    # the average with garbage.
    case "$wall" in
      ''|*[!0-9.]*) continue ;;
    esac

    local dur; dur="$(clip_duration "$wav")"
    total_wall="$(echo "$total_wall + $wall" | bc -l)"
    total_dur="$(echo "$total_dur + $dur" | bc -l)"
    [ -n "$kb" ] && [ "$kb" -gt "$peak_kb" ] 2>/dev/null && peak_kb="$kb"
    n=$((n+1))

    # WER against the reference we recorded alongside the audio.
    if [ -f "$FIXTURES/$base.txt" ] && [ -f "$out.txt" ]; then
      local w; w="$(wer "$FIXTURES/$base.txt" "$out.txt")"
      if [ "$w" != "na" ]; then
        wer_sum="$(echo "$wer_sum + $w" | bc -l)"
        wer_n=$((wer_n+1))
      fi
    fi
  done

  [ "$n" -eq 0 ] && { echo "| $label | — | — | — | no clips ran |"; return; }

  local avg_wall rtf peak_mb avg_wer
  avg_wall="$(echo "scale=2; $total_wall / $n" | bc -l)"
  rtf="$(echo "scale=2; $total_wall / $total_dur" | bc -l)"
  if [ "$peak_kb" -gt 0 ] 2>/dev/null; then
    peak_mb="$(echo "scale=0; $peak_kb / 1024" | bc -l) MB"
  else
    peak_mb="n/a"
  fi
  if [ "$wer_n" -gt 0 ]; then
    avg_wer="$(echo "scale=1; $wer_sum / $wer_n" | bc -l)%"
  else
    avg_wer="—"
  fi

  echo "| $label | ${avg_wall}s | ${rtf}x | ${peak_mb} | ${avg_wer} |"
}

# --- Report ----------------------------------------------------------------

{
echo "# Bob STT benchmark — $STAMP"
echo
echo "## Machine"
echo
echo "- CPU: $CPU"
echo "- Cores: $CORES"
echo "- Memory: $MEM"
echo "- NVIDIA GPU present: $HAS_NVIDIA"
echo
if [ "$HAS_NVIDIA" = "yes" ]; then
  echo "> **WARNING:** an NVIDIA GPU is present. If this is the dev box rather"
  echo "> than the target NUC, these numbers do not represent the deployment"
  echo "> target and must not be used to select a model."
  echo
fi
echo "## Results"
echo
echo "Averages over $(ls -1 "$FIXTURES"/*.wav | wc -l) fixture clips."
echo "Real-time factor (RTF) below 1.0 means faster than real time."
echo
echo "| Configuration | Avg wall | RTF | Peak RSS | WER |"
echo "|---|---|---|---|---|"

CPU_BIN="$WHISPER/build-cpu/bin/whisper-cli"
OV_BIN="$WHISPER/build-ov/bin/whisper-cli"

run_config "CPU large-v3-turbo-q5_0" "$CPU_BIN" "$WHISPER/models/ggml-large-v3-turbo-q5_0.bin"
run_config "CPU medium"              "$CPU_BIN" "$WHISPER/models/ggml-medium.bin"
run_config "CPU small"               "$CPU_BIN" "$WHISPER/models/ggml-small.bin"

if [ -x "$OV_BIN" ]; then
  # OpenVINO accelerates the ENCODER only; the decoder still runs on CPU.
  run_config "OpenVINO iGPU large-v3-turbo-q5_0" "$OV_BIN" "$WHISPER/models/ggml-large-v3-turbo-q5_0.bin" "-oved GPU"
  run_config "OpenVINO iGPU small"               "$OV_BIN" "$WHISPER/models/ggml-small.bin" "-oved GPU"
else
  echo "| OpenVINO iGPU | — | — | — | build missing |"
fi

echo
if [ "$RUN_LOAD" -eq 1 ]; then
  echo "### Under concurrent load"
  echo
  echo "Busy loops on half the cores, standing in for co-tenant applications."
  echo
  echo "| Configuration | Avg wall | RTF | Peak RSS | WER |"
  echo "|---|---|---|---|---|"
  # Busy loops stand in for co-tenant applications. They MUST be cleaned up on
  # every exit path, including Ctrl-C, or they peg cores indefinitely.
  LOAD_PIDS=()
  for _ in $(seq 1 $((CORES/2))); do
    ( while :; do :; done ) & LOAD_PIDS+=($!)
  done
  stop_load() {
    [ ${#LOAD_PIDS[@]} -gt 0 ] || return 0
    kill "${LOAD_PIDS[@]}" 2>/dev/null || true
    wait "${LOAD_PIDS[@]}" 2>/dev/null || true
    LOAD_PIDS=()
  }
  trap stop_load EXIT INT TERM

  run_config "LOADED CPU large-v3-turbo-q5_0" "$CPU_BIN" "$WHISPER/models/ggml-large-v3-turbo-q5_0.bin"
  # Note the `if`: a bare `[ -x ... ] && run_config ...` returns false when the
  # build is absent, which under `set -e` aborts the whole report.
  if [ -x "$OV_BIN" ]; then
    run_config "LOADED OpenVINO iGPU large-v3-turbo-q5_0" "$OV_BIN" "$WHISPER/models/ggml-large-v3-turbo-q5_0.bin" "-oved GPU"
  fi

  stop_load
  trap - EXIT INT TERM
  echo
else
  echo "_Concurrent-load pass not run. Re-run with \`--load\` — that is the"
  echo "number that actually decides model selection._"
  echo
fi

echo "## Pass criteria (SPEC section 17)"
echo
echo "- end-of-speech to final transcript: **< 500 ms**"
echo "- end-of-speech to first audio out, whole pipeline: **< 1 s**"
echo
echo "These are STREAMING targets. This harness measures batch transcription of"
echo "complete files, which is a LOWER BOUND on streaming latency, not the same"
echo "quantity. A configuration that cannot transcribe an 8-second clip in well"
echo "under 8 seconds certainly cannot stream inside the budget; one that can is"
echo "a candidate, to be confirmed in Phase 2 with live audio and VAD."
echo
echo "## What this does not measure"
echo
echo "- Live microphone capture, VAD segmentation, or end-of-turn detection."
echo "- Time to first partial transcript (this is batch, not streaming)."
echo "- SCRFD or CVLFace, which compete for the same cores in Phase 3."
echo "- Any physical capability whatsoever."
} | tee "$REPORT"

echo
echo "Report written to $REPORT"
