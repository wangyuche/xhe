#!/bin/bash
# 均線三刀流一鍵執行:抓 Fugle 60 分 K(歷史約 180 天 + 今天盤中)→ 三條均線判斷 → 輸出文字與 SVG。
# 用法: bash run.sh [代號,預設 IX0001] [輸出目錄,預設 ~/.claude/tg/work]
# 需要 ~/.claude/tg/fugle.sh(含 Fugle 金鑰;FUGLE_SH 可指定別的路徑)。不使用 here-string / heredoc(沙盒不准寫 /tmp)。
# 每次執行前先刪掉上次的資料檔;歷史 K 抓不到就報錯結束(不沿用舊檔),盤中 K 抓不到時只用歷史。
SYM="${1:-IX0001}"
OUT="${2:-$HOME/.claude/tg/work}"
DIR="$(cd "$(dirname "$0")" && pwd)"
[[ "$SYM" =~ ^[A-Za-z0-9]+$ ]] || { echo "用法錯誤: 代號只能是英數字($SYM)" >&2; exit 2; }
FUGLE="${FUGLE_SH:-$HOME/.claude/tg/fugle.sh}"
[ -f "$FUGLE" ] || { echo "資料錯誤: 找不到 $FUGLE(Fugle 包裝腳本,見 xhe README「台股」一節)" >&2; exit 1; }
mkdir -p "$OUT" || exit 1
FROM=$(python3 -I -c 'import datetime as d; print((d.date.today()-d.timedelta(days=180)).isoformat())')
TO=$(python3 -I -c 'import datetime as d; print(d.date.today().isoformat())')
fetch() {
  local st rc
  st=$(bash "$FUGLE" "$1" "$2" 2>/dev/null); rc=$?
  [ "$rc" = 0 ] || { echo "Fugle 失敗(結束碼 $rc):${st:-無輸出}" >&2; return 1; }
  if printf '%s' "$st" | grep -q '"http"' && ! printf '%s' "$st" | grep -Eq '"http" *: *200([^0-9]|$)'; then
    echo "Fugle 回應: $st" >&2; return 1
  fi
  [ -s "$2" ] || { echo "Fugle 沒有寫出資料(${st:-無輸出})" >&2; return 1; }
  python3 -I -c 'import json,sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: sys.exit(f"Fugle 回應不是完整的 JSON:{e}")
if not isinstance(d, dict) or not isinstance(d.get("data"), list): sys.exit("Fugle 回應沒有 data:" + str(d)[:200])' "$2"
}
if [ "$SYM" = "IX0001" ]; then NAME="加權指數"; else
  CNAME=$(bash "$FUGLE" "intraday/quote/$SYM" 2>/dev/null | jq -r 'if type == "object" and .symbol then .name // empty else empty end' 2>/dev/null)
  NAME="$SYM${CNAME:+ $CNAME}"
fi
NOW=$(TZ=Asia/Taipei date +%u%H%M)
IN_SESSION="${TW_IN_SESSION:-$([ "${NOW:0:1}" -le 5 ] && [ "${NOW:1}" -ge 0900 ] && echo 1 || echo 0)}"
H="$OUT/blades_${SYM}_60m_hist.json"; I="$OUT/blades_${SYM}_60m_intraday.json"; J="$OUT/blades_${SYM}_60m.json"
rm -f "$OUT/blades_${SYM}_60m.svg" "$H" "$I" "$J"
fail() { echo "$1" >&2; rm -f "$H" "$I" "$J"; exit 1; }
fetch "historical/candles/$SYM?timeframe=60&from=$FROM&to=$TO" "$H" \
  || fail "資料錯誤: 60 分 K 歷史資料抓不到(原因見上一行),不使用舊資料"
if ! ERR=$(fetch "intraday/candles/$SYM?timeframe=60" "$I" 2>&1); then
  rm -f "$I"
  [ "$IN_SESSION" = 1 ] && echo "$ERR"$'\n'"警告: 60 分 K 盤中資料抓不到,只用歷史 K,結果可能缺今天盤中" >&2
fi
python3 -I "$DIR/combine.py" "$H" "$I" "$J" || fail "資料錯誤: 60 分 K 合併失敗"
python3 -I "$DIR/three_blades.py" "$J" --title "$NAME" --svg "$OUT/blades_${SYM}_60m.svg"
