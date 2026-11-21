#!/bin/bash
# 底部訊號一鍵執行:抓 Fugle 30/60 分 K(歷史 + 今天盤中)→ 依序判斷 ①~⑥ → 30 分 K 到 ② 以上才輸出 SVG。
# 用法: bash run.sh [代號,預設 IX0001] [輸出目錄,預設 ~/.claude/tg/work]
# 需要 ~/.claude/tg/fugle.sh(含 Fugle 金鑰;FUGLE_SH 可指定別的路徑)。不使用 here-string / heredoc(沙盒不准寫 /tmp)。
# 每次執行前先刪掉上次的資料檔;歷史 K 抓不到就報錯結束(不沿用舊檔),盤中 K 抓不到時只用歷史(交易日 09:00 後才警告,收盤後歷史 K 也還沒有今天)。
SYM="${1:-IX0001}"
OUT="${2:-$HOME/.claude/tg/work}"
DIR="$(cd "$(dirname "$0")" && pwd)"
[[ "$SYM" =~ ^[A-Za-z0-9]+$ ]] || { echo "用法錯誤: 代號只能是英數字($SYM)" >&2; exit 2; }
FUGLE="${FUGLE_SH:-$HOME/.claude/tg/fugle.sh}"
[ -f "$FUGLE" ] || { echo "資料錯誤: 找不到 $FUGLE(Fugle 包裝腳本,見 xhe README「台股」一節)" >&2; exit 1; }
mkdir -p "$OUT" || exit 1
FROM=$(python3 -I -c 'import datetime as d; print((d.date.today()-d.timedelta(days=45)).isoformat())')
TO=$(python3 -I -c 'import datetime as d; print(d.date.today().isoformat())')
# fugle.sh <endpoint> <檔案> 通常印 {"http":<狀態碼>}。成功 = fugle.sh 結束碼 0、沒有印出非 200 的狀態碼,
# 且檔案是含 data 陣列的 JSON(檔案事先刪掉,所以一定是這次寫的;逾時截斷或錯誤內容都算失敗)
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
# 圖標題:指數用中文名;個股用「代號 公司名」(名稱取自 Fugle 報價,抓不到就只放代號)
if [ "$SYM" = "IX0001" ]; then NAME="加權指數"; else
  CNAME=$(bash "$FUGLE" "intraday/quote/$SYM" 2>/dev/null | jq -r 'if type == "object" and .symbol then .name // empty else empty end' 2>/dev/null)
  NAME="$SYM${CNAME:+ $CNAME}"
fi
# 今天應該有盤中 K 的時間(台北週一到週五 09:00 之後,收盤後歷史 K 仍不含今天;TW_IN_SESSION=0/1 可覆寫,測試用)
NOW=$(TZ=Asia/Taipei date +%u%H%M)
IN_SESSION="${TW_IN_SESSION:-$([ "${NOW:0:1}" -le 5 ] && [ "${NOW:1}" -ge 0900 ] && echo 1 || echo 0)}"
rm -f "$OUT/bottom_${SYM}_30m.svg" "$OUT/bottom_${SYM}_"{30,60}m{,_hist,_intraday}.json
# 失敗時連這次已寫出的檔案一起刪,避免留下半套結果
fail() { echo "$1" >&2; rm -f "$OUT/bottom_${SYM}_"{30,60}m{,_hist,_intraday}.json; exit 1; }
for TF in 30 60; do
  H="$OUT/bottom_${SYM}_${TF}m_hist.json"; I="$OUT/bottom_${SYM}_${TF}m_intraday.json"; J="$OUT/bottom_${SYM}_${TF}m.json"
  # 歷史 K 不含今天盤中,另外抓 intraday 接在後面
  fetch "historical/candles/$SYM?timeframe=$TF&from=$FROM&to=$TO" "$H" \
    || fail "資料錯誤: ${TF} 分 K 歷史資料抓不到(原因見上一行),不使用舊資料"
  if ! ERR=$(fetch "intraday/candles/$SYM?timeframe=$TF" "$I" 2>&1); then
    rm -f "$I"
    # 週末、開盤前本來就沒有盤中 K,只用歷史是正常的,不警告
    [ "$IN_SESSION" = 1 ] && echo "$ERR"$'\n'"警告: ${TF} 分 K 盤中資料抓不到,只用歷史 K,結果缺今天盤中" >&2
  elif [ "$IN_SESSION" = 1 ] && python3 -I -c 'import json,sys; sys.exit(0 if not json.load(open(sys.argv[1]))["data"] else 1)' "$I"; then
    echo "警告: ${TF} 分 K 盤中資料是空的(Fugle 尚未更新或今天休市),結果缺今天盤中" >&2
  fi
  python3 -I "$DIR/combine.py" "$H" "$I" "$J" || fail "資料錯誤: ${TF} 分 K 合併失敗"
done
python3 -I "$DIR/bottom_signal.py" "$OUT/bottom_${SYM}_30m.json" "$OUT/bottom_${SYM}_60m.json" \
  --title "$NAME" --svg "$OUT/bottom_${SYM}_30m.svg"
