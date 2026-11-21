#!/bin/bash
# 底部訊號一鍵執行:抓 Fugle 30/60 分 K(歷史 + 今天盤中)→ 依序判斷 ①~⑥ → 30 分 K 到 ② 以上才輸出 SVG。
# 用法: bash run.sh [代號,預設 IX0001] [輸出目錄,預設 ~/.claude/tg/work]
# 需要 ~/.claude/tg/fugle.sh(含 Fugle 金鑰;FUGLE_SH 可指定別的路徑)。不使用 here-string / heredoc(沙盒不准寫 /tmp)。
# 每次執行前先刪掉上次的資料檔;歷史 K 抓不到就報錯結束(不沿用舊檔),盤中 K 抓不到時警告並只用歷史。
SYM="${1:-IX0001}"
OUT="${2:-$HOME/.claude/tg/work}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FUGLE="${FUGLE_SH:-$HOME/.claude/tg/fugle.sh}"
[ -f "$FUGLE" ] || { echo "資料錯誤: 找不到 $FUGLE(Fugle 包裝腳本,見 xhe README「台股」)" >&2; exit 1; }
mkdir -p "$OUT" || exit 1
FROM=$(python3 -I -c 'import datetime as d; print((d.date.today()-d.timedelta(days=45)).isoformat())')
TO=$(python3 -I -c 'import datetime as d; print(d.date.today().isoformat())')
# fugle.sh <endpoint> <檔案> 通常印 {"http":<狀態碼>}。成功 = 有寫出非空檔案,且沒有印出非 200 的狀態碼
# (檔案事先刪掉,所以非空一定是這次寫的;內容是否為有效 K 線由 combine.py 檢查)
fetch() {
  local st
  st=$(bash "$FUGLE" "$1" "$2" 2>/dev/null)
  if printf '%s' "$st" | grep -q '"http"' && ! printf '%s' "$st" | grep -Eq '"http" *: *200([^0-9]|$)'; then
    echo "Fugle 回應: $st" >&2; return 1
  fi
  [ -s "$2" ] || { echo "Fugle 沒有寫出資料(${st:-無輸出})" >&2; return 1; }
}
# 圖標題:指數用中文名;個股用「代號 公司名」(名稱取自 Fugle 報價,抓不到就只放代號)
if [ "$SYM" = "IX0001" ]; then NAME="加權指數"; else
  CNAME=$(bash "$FUGLE" "intraday/quote/$SYM" | jq -r '.name // empty' 2>/dev/null)
  NAME="$SYM${CNAME:+ $CNAME}"
fi
rm -f "$OUT/bottom_${SYM}_30m.svg" "$OUT/bottom_${SYM}_"{30,60}m{,_hist,_intraday}.json
for TF in 30 60; do
  H="$OUT/bottom_${SYM}_${TF}m_hist.json"; I="$OUT/bottom_${SYM}_${TF}m_intraday.json"; J="$OUT/bottom_${SYM}_${TF}m.json"
  # 歷史 K 不含今天盤中,另外抓 intraday 接在後面
  fetch "historical/candles/$SYM?timeframe=$TF&from=$FROM&to=$TO" "$H" \
    || { echo "資料錯誤: ${TF} 分 K 歷史資料抓不到(原因見上一行),不使用舊資料" >&2; exit 1; }
  fetch "intraday/candles/$SYM?timeframe=$TF" "$I" \
    || { echo "警告: ${TF} 分 K 盤中資料抓不到,只用歷史 K(交易時間內結果會缺今天)" >&2; rm -f "$I"; }
  python3 -I "$DIR/combine.py" "$H" "$I" "$J" || exit 1
done
python3 -I "$DIR/bottom_signal.py" "$OUT/bottom_${SYM}_30m.json" "$OUT/bottom_${SYM}_60m.json" \
  --title "$NAME" --svg "$OUT/bottom_${SYM}_30m.svg"
