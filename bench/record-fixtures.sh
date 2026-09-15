#!/usr/bin/env bash
# Record the benchmark fixture set: ten Swedish and ten English utterances.
#
# These are YOUR voice in YOUR room, which is the point — word error rate on
# LibriSpeech tells you nothing about whether Bob understands you at a desk.
#
# Records 16 kHz mono WAV, which is what whisper.cpp wants natively.
#
# Usage:  ./bench/record-fixtures.sh [outdir]
#         outdir defaults to ~/bob-bench/fixtures

set -euo pipefail

OUTDIR="${1:-$HOME/bob-bench/fixtures}"
SECONDS_PER_CLIP=8

mkdir -p "$OUTDIR"

command -v ffmpeg >/dev/null 2>&1 || { echo "ffmpeg required" >&2; exit 1; }

# Sentences chosen to exercise what Bob actually hears: names, questions,
# numbers, and a couple of things a child would say.
# shellcheck disable=SC2034  # consumed via nameref in record_set
# Diacritics are deliberate: å/ä/ö are exactly where Swedish ASR degrades, so
# stripping them would flatter the WER on the characters that matter most.
SV=(
  "Hej Bob, vad heter du?"
  "Var la jag skruvmejseln?"
  "Kan du titta åt vänster?"
  "Det här är min lillebror Olle."
  "Vi byggde en dinosaurie som heter Knut."
  "Hur mycket är tjugoåtta plus fjorton?"
  "Kommer du ihåg vad vi pratade om igår?"
  "Bob, kan du sluta prata nu?"
  "Jag heter Gustaf och jag bor i Sverige."
  "Knut äter lampor, det är ganska konstigt."
)

# shellcheck disable=SC2034  # consumed via nameref in record_set
EN=(
  "Hey Bob, what is your name?"
  "Where did I put the screwdriver?"
  "Can you look to the left please?"
  "This is my little brother Olle."
  "We built a dinosaur called Knut."
  "What is twenty eight plus fourteen?"
  "Do you remember what we talked about yesterday?"
  "Bob, stop talking for a moment."
  "My name is Gustaf and I live in Sweden."
  "Knut eats lamps, which is fairly strange."
)

record_set() {
  local lang="$1"; shift
  local -n arr="$1"
  local i=1
  for sentence in "${arr[@]}"; do
    local out
    out="$(printf '%s/%s-%02d.wav' "$OUTDIR" "$lang" "$i")"
    if [ -f "$out" ]; then
      echo "  [$lang $i] already recorded, skipping"
      i=$((i+1))
      continue
    fi
    echo
    echo "  [$lang $i/10] Say:  $sentence"
    read -r -p "  Press Enter to record ${SECONDS_PER_CLIP}s (or s to skip) " ans
    [ "$ans" = "s" ] && { i=$((i+1)); continue; }
    ffmpeg -hide_banner -loglevel error \
      -f alsa -i default \
      -t "$SECONDS_PER_CLIP" -ar 16000 -ac 1 \
      "$out"
    echo "  saved $out"
    # Store the reference text next to the audio for word error rate scoring.
    printf '%s\n' "$sentence" > "${out%.wav}.txt"
    i=$((i+1))
  done
}

echo "Recording to $OUTDIR"
echo "Speak normally, at the distance you would actually sit from Bob."
echo

record_set sv SV
record_set en EN

echo
echo "Done. Recorded fixtures:"
ls -1 "$OUTDIR"/*.wav 2>/dev/null | wc -l
echo "Reference transcripts are stored alongside as .txt for WER scoring."
