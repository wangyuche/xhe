#!/bin/bash
# 底部訊號一鍵執行:抓 Fugle 30/60 分 K(歷史 + 今天盤中)→ 依序判斷 ①~⑥ → 30 分 K 到 ② 以上才輸出 SVG。
# 用法: bash run.sh [代號,預設 IX0001] [輸出目錄,預設 ~/.claude/tg/work]
# 需要 ~/.claude/tg/fugle.sh(含 Fugle 金鑰)。不使用 here-string / heredoc(沙盒不准寫 /tmp)。
SYM="${1:-IX0001}"
OUT="${2:-$HOME/.claude/tg/work}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FUGLE="$HOME/.claude/tg/fugle.sh"
FROM=$(python3 -I -c 'import datetime as d; print((d.date.today()-d.timedelta(days=45)).isoformat())')
TO=$(python3 -I -c 'import datetime as d; print(d.date.today().isoformat())')
NAME="$SYM"; [ "$SYM" = "IX0001" ] && NAME="加權指數"
for TF in 30 60; do
  H="$OUT/bottom_${SYM}_${TF}m_hist.json"; I="$OUT/bottom_${SYM}_${TF}m_intraday.json"; J="$OUT/bottom_${SYM}_${TF}m.json"
  # 歷史 K 不含今天盤中,另外抓 intraday 接在後面
  bash "$FUGLE" "historical/candles/$SYM?timeframe=$TF&from=$FROM&to=$TO" "$H" > /dev/null
  bash "$FUGLE" "intraday/candles/$SYM?timeframe=$TF" "$I" > /dev/null
  python3 -I "$DIR/combine.py" "$H" "$I" "$J" || exit 1
done
python3 -I "$DIR/bottom_signal.py" "$OUT/bottom_${SYM}_30m.json" "$OUT/bottom_${SYM}_60m.json" \
  --title "$NAME" --svg "$OUT/bottom_${SYM}_30m.svg"
