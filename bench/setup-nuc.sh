#!/usr/bin/env bash
# Set up the Bob STT benchmark on the target NUC.
#
# Run this ON THE NUC, not on the dev box. It installs whisper.cpp (CPU and
# OpenVINO builds), downloads the candidate models, and prepares the OpenVINO
# encoder IR files.
#
# Idempotent: safe to re-run. Skips work that is already done.
#
# Usage:  ./bench/setup-nuc.sh [workdir]
#         workdir defaults to ~/bob-bench

set -euo pipefail

WORKDIR="${1:-$HOME/bob-bench}"
OPENVINO_VERSION="2026.3.0"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# --- Sanity: are we actually on the target? -------------------------------

say "Checking this is the target machine"
CPU="$(grep -m1 '^model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//')"
echo "CPU: $CPU"

if ! ls /dev/dri/renderD* >/dev/null 2>&1; then
  warn "No /dev/dri render node found — the iGPU path will not work."
fi

if lspci 2>/dev/null | grep -qi nvidia; then
  warn "An NVIDIA GPU is present. If this is the dev box, STOP: these numbers"
  warn "will not represent the NUC. See bench/README.md."
fi

case "$CPU" in
  *Intel*) ;;
  *) warn "CPU is not Intel. The OpenVINO iGPU path assumes Intel graphics." ;;
esac

mkdir -p "$WORKDIR"
cd "$WORKDIR"

# --- Dependencies ----------------------------------------------------------

say "Checking build dependencies"
MISSING=()
for tool in git cmake make g++ ffmpeg python3; do
  command -v "$tool" >/dev/null 2>&1 || MISSING+=("$tool")
done
if [ ${#MISSING[@]} -gt 0 ]; then
  die "Missing tools: ${MISSING[*]}
Install them with your distribution's package manager, then re-run.
On Debian/Ubuntu: sudo apt install git cmake build-essential ffmpeg python3"
fi

# --- whisper.cpp source ----------------------------------------------------

if [ ! -d whisper.cpp ]; then
  say "Cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp
else
  say "whisper.cpp already cloned"
fi

cd whisper.cpp

# --- CPU build -------------------------------------------------------------

if [ ! -x build-cpu/bin/whisper-cli ]; then
  say "Building whisper.cpp (CPU)"
  cmake -B build-cpu -DCMAKE_BUILD_TYPE=Release
  cmake --build build-cpu -j"$(nproc)" --config Release
else
  say "CPU build already present"
fi

# --- Models ----------------------------------------------------------------

say "Downloading models (this may take a while)"
# large-v3-turbo-q5_0 is the SPEC default. small and medium are the fallbacks
# the latency escalation path names.
for m in large-v3-turbo-q5_0 medium small; do
  if [ ! -f "models/ggml-$m.bin" ]; then
    echo "  downloading $m"
    sh ./models/download-ggml-model.sh "$m" || warn "could not download $m"
  else
    echo "  $m already present"
  fi
done

# --- OpenVINO --------------------------------------------------------------

say "OpenVINO setup"
OV_DIR="$WORKDIR/openvino"

if [ -f "$OV_DIR/setupvars.sh" ]; then
  echo "OpenVINO already unpacked at $OV_DIR"
else
  cat <<EOF
OpenVINO $OPENVINO_VERSION is not installed at $OV_DIR.

whisper.cpp's OpenVINO path needs the OpenVINO runtime. Install it one of
two ways, then re-run this script:

  A) Archive (what whisper.cpp documents):
     Download the Linux archive for $OPENVINO_VERSION from
       https://storage.openvinotoolkit.org/repositories/openvino/packages/
     then:
       mkdir -p $OV_DIR
       tar -xf <archive>.tgz --strip-components=1 -C $OV_DIR

  B) Your distribution's package, if it ships OpenVINO $OPENVINO_VERSION
     or newer, and then symlink or set OV_DIR accordingly.

You also need the Intel compute runtime for the iGPU to be a usable device:
  Debian/Ubuntu: sudo apt install intel-opencl-icd
  Arch:          sudo pacman -S intel-compute-runtime

Verify the GPU is visible afterwards with:
  python3 -c "import openvino as ov; print(ov.Core().available_devices)"
It must list GPU, not just CPU.
EOF
  warn "Skipping OpenVINO build. CPU benchmarks will still run."
  exit 0
fi

# shellcheck disable=SC1091
source "$OV_DIR/setupvars.sh"

if [ ! -x build-ov/bin/whisper-cli ]; then
  say "Building whisper.cpp (OpenVINO)"
  cmake -B build-ov -DWHISPER_OPENVINO=1 -DCMAKE_BUILD_TYPE=Release
  cmake --build build-ov -j"$(nproc)" --config Release
else
  say "OpenVINO build already present"
fi

say "Generating OpenVINO encoder IR"
# OpenVINO accelerates the ENCODER only; the decoder stays on CPU. This is why
# the iGPU speedup is real but partial.
if [ -d models/openvino-conv-env ]; then
  echo "conversion env already present"
else
  python3 -m venv models/openvino-conv-env
  # shellcheck disable=SC1091
  source models/openvino-conv-env/bin/activate
  python3 -m pip install --upgrade pip
  python3 -m pip install -r models/requirements-openvino.txt \
    || warn "could not install conversion requirements"
  deactivate
fi

# shellcheck disable=SC1091
source models/openvino-conv-env/bin/activate
for m in large-v3-turbo medium small; do
  if [ ! -f "models/ggml-$m-encoder-openvino.xml" ]; then
    echo "  converting $m encoder"
    python3 models/convert-whisper-to-openvino.py --model "$m" \
      || warn "conversion failed for $m"
  fi
done
deactivate

say "Setup complete"
cat <<EOF

Workdir:     $WORKDIR
CPU build:   $WORKDIR/whisper.cpp/build-cpu/bin/whisper-cli
OV build:    $WORKDIR/whisper.cpp/build-ov/bin/whisper-cli

Next:
  1. Record the fixture set (see bench/record-fixtures.sh)
  2. Run   ./bench/run-bench.sh $WORKDIR
EOF
