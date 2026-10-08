#!/bin/bash
# multitrack — split a song into as many stems as the models allow, at true level
#
# Usage:  multitrack [-o OUTDIR] [-k] <audio file>
#
#   Cascade (every stage via `stems -t`, so nothing gets re-normalized):
#     1. BS-Roformer          vocals / instrumental
#     2. Karaoke Roformer     lead / backing vocals
#     3. htdemucs_ft          drums / bass / other   (on the instrumental)
#     4. htdemucs_6s          piano / guitar         (on "other")
#     5. MDX23C DrumSep       kick / snare / toms / hh / ride / crash   (on drums)
#   Output: 13 numbered 32-bit float WAVs that sum back to the input (13 Residual is
#   whatever the models dropped), plus a null-test report.
#
#   -o  output folder (default: $TRANSCRIPTIONS_DIR/<input name> Stems, where
#       TRANSCRIPTIONS_DIR defaults to ./Transcriptions)
#   -k  keep the _work folder with every intermediate stem (deleted by default)
#
# Environment (optional): TRANSCRIPTIONS_DIR as above; STEMS_CMD (default: the `stems`
# next to this script, else PATH); AUDIO_SEPARATOR_PYTHON, a Python with numpy +
# soundfile (default: the `uv tool` env of audio-separator, else python3).
#
# Takes ~5x the song's length on an Apple M3 Pro (4-min song ≈ 20 min).

set -euo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
PY="${AUDIO_SEPARATOR_PYTHON:-$HOME/.local/share/uv/tools/audio-separator/bin/python}"   # has numpy + soundfile
[ -n "${AUDIO_SEPARATOR_PYTHON:-}" ] || [ -x "$PY" ] || PY="python3"
ROOT="${TRANSCRIPTIONS_DIR:-$PWD/Transcriptions}"
STEMS="${STEMS_CMD:-$HERE/stems}"
[ -n "${STEMS_CMD:-}" ] || [ -x "$STEMS" ] || STEMS="stems"

usage() { awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit "${1:-0}"; }
OUT=""; keep=0
while getopts ":o:kh" opt; do
  case $opt in
    o) OUT="$OPTARG" ;;
    k) keep=1 ;;
    h) usage 0 ;;
    *) echo "unknown option -$OPTARG" >&2; usage 1 ;;
  esac
done
shift $((OPTIND - 1))
[ $# -eq 1 ] && [ -f "$1" ] || usage 1
SRC="$1"
name="$(basename "${SRC%.*}")"
[ -n "$OUT" ] || OUT="$ROOT/$name Stems"
W="$OUT/_work"; mkdir -p "$W"

log(){ echo "[$(date +%H:%M:%S)] $*"; }
pick(){ local f; f=$(find "$1" -maxdepth 1 -type f -iname "*($2)*" | head -1)
        [ -n "$f" ] || { echo "missing stem '$2' in $1" >&2; ls "$1" >&2; exit 1; }; echo "$f"; }
# a stage whose folder already has stems is skipped, so a crashed run resumes
stage(){ local dir="$W/$1" model="$2" in="$3"
         [ -n "$(ls -A "$dir" 2>/dev/null)" ] || "$STEMS" -t -m "$model" -o "$dir" "$in"; }

# 44.1 kHz: audio-separator resamples to that and writes its stems at that rate
[ -f "$W/mix.wav" ] || ffmpeg -nostdin -loglevel error -y -i "$SRC" -map 0:a:0 -ar 44100 -c:a pcm_f32le "$W/mix.wav"

log "1/5 vocals / instrumental (BS-Roformer)"
stage 1_rofo rofo "$W/mix.wav"
cp "$(pick "$W/1_rofo" Vocals)" "$W/vocals.wav"
cp "$(pick "$W/1_rofo" Instrumental)" "$W/instrumental.wav"

log "2/5 lead / backing vocals (karaoke Roformer)"
stage 2_karaoke mel_band_roformer_karaoke_aufr33_viperx_sdr_10.1956.ckpt "$W/vocals.wav"

log "3/5 drums / bass / other (htdemucs_ft)"
stage 3_ft ft "$W/instrumental.wav"
cp "$(pick "$W/3_ft" Drums)" "$W/drums.wav"
cp "$(pick "$W/3_ft" Other)" "$W/other.wav"

log "4/5 piano / guitar out of other (htdemucs_6s)"
stage 4_6s 6s "$W/other.wav"

log "5/5 drum kit pieces (DrumSep)"
stage 5_drumsep MDX23C-DrumSep-aufr33-jarredou.ckpt "$W/drums.wav"

log "assembling"
"$PY" "$HERE/assemble.py" "$OUT"
chflags nohidden "$OUT"/*.wav 2>/dev/null || true
[ "$keep" -eq 1 ] || rm -rf "$W"
log "done -> $OUT"
