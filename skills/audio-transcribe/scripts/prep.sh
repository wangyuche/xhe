#!/bin/bash
# Step 1: convert any audio/video file to 16 kHz mono WAV (what whisper.cpp reads), print info.
# Usage: bash prep.sh <input audio/video> <out.wav>
set -e
IN="$1"; OUT="$2"
[ -f "$IN" ] || { echo "找不到輸入檔: $IN"; exit 1; }
[ -n "$OUT" ] || { echo "用法: prep.sh <input> <out.wav>"; exit 1; }
DUR=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$IN")
ffmpeg -y -loglevel error -i "$IN" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$OUT"
python3 -I -c 'import sys; d=float(sys.argv[1]); print(f"duration_sec={d:.0f} ({d/60:.1f} min)")' "$DUR"
echo "wav=$OUT"
