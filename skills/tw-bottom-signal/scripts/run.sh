#!/bin/bash
# 底部訊號一鍵執行:抓 Fugle 30/60 分 K → 判斷 4 訊號 → 有訊號才輸出 PNG。
# 用法: bash run.sh [代號,預設 IX0001] [輸出目錄,預設 ~/.claude/tg/work] [--dmin N]
# 需要 ~/.claude/tg/fugle.sh(含 Fugle 金鑰)。不使用 here-string / heredoc(沙盒不准寫 /tmp)。
SYM="${1:-IX0001}"
OUT="${2:-$HOME/.claude/tg/work}"
DMIN="${4:-20}"; [ "$3" = "--dmin" ] || DMIN=20
DIR="$(cd "$(dirname "$0")" && pwd)"
FUGLE="$HOME/.claude/tg/fugle.sh"
FROM=$(python3 -I -c 'import datetime as d; print((d.date.today()-d.timedelta(days=45)).isoformat())')
TO=$(python3 -I -c 'import datetime as d; print(d.date.today().isoformat())')
NAME="$SYM"; [ "$SYM" = "IX0001" ] && NAME="加權指數"
for TF in 30 60; do
  J="$OUT/bottom_${SYM}_${TF}m.json"
  bash "$FUGLE" "historical/candles/$SYM?timeframe=$TF&from=$FROM&to=$TO" "$J" > "$OUT/bottom_${SYM}_${TF}m.http"
  python3 -I "$DIR/bottom_signal.py" "$J" "${TF}分K" --dmin "$DMIN" --title "$NAME" --svg "$OUT/bottom_${SYM}_${TF}m.svg"
  echo
done
