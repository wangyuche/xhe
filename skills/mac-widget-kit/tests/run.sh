#!/bin/bash
# mac-widget-kit 骨架測試:在暫存目錄建立範例 widget,以 desktop / menubar / both 三種 placement
# 檢查 build、--once、snapshot、--self-check、骨架 diff 與邊界情況。結束時刪除暫存目錄。
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/scripts"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/mwk-test.XXXXXX")"
LOCKPID=""; DUP=""
trap '[ -n "$LOCKPID" ] && kill $LOCKPID 2>/dev/null; [ -n "$DUP" ] && kill $DUP 2>/dev/null; rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { echo "PASS  $1"; pass=$((pass+1)); }
ng()  { echo "FAIL  $1"; [ $# -ge 2 ] && echo "      $2"; fail=$((fail+1)); }
check() { local name="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$name"; else ng "$name"; fi; }

D="$TMP/t-sample"
bash "$S/new-widget.sh" t-sample "$D" >/dev/null || { echo "new-widget.sh 失敗"; exit 1; }
BIN="$D/build/TSample.app/Contents/MacOS/TSample"
PLIST="$D/build/TSample.app/Contents/Info.plist"

# 邊界:目錄已存在時 new-widget.sh 要失敗
if bash "$S/new-widget.sh" t-sample "$D" >/dev/null 2>&1; then ng "new-widget:目錄已存在要失敗"; else ok "new-widget:目錄已存在要失敗"; fi
# 邊界:不合法名稱
if bash "$S/new-widget.sh" "Bad_Name" "$TMP/bad" >/dev/null 2>&1; then ng "new-widget:不合法名稱要失敗"; else ok "new-widget:不合法名稱要失敗"; fi

for placement in desktop menubar both; do
  sed -i '' -E "s/\"placement\": \"[a-z]+\"/\"placement\": \"$placement\"/" "$D/widget.json"
  out="$(bash "$S/build.sh" "$D" 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && grep -q '^警告:0$' <<<"$out"; then ok "[$placement] build 成功、警告 0"; else ng "[$placement] build" "$(tail -5 <<<"$out")"; fi
  [ "$(plutil -extract LSUIElement raw "$PLIST" 2>/dev/null)" = "true" ] && ok "[$placement] LSUIElement=true" || ng "[$placement] LSUIElement"

  once="$("$BIN" --once 2>&1)"; rc=$?
  if [ $rc -eq 0 ] && plutil -convert json -o /dev/null - <<<"$once" 2>/dev/null; then ok "[$placement] --once 輸出 JSON"; else ng "[$placement] --once" "$once"; fi

  snap="$(bash "$S/snapshot.sh" "$D" 2>&1)"; rc=$?
  w=$(sips -g pixelWidth "$D/build/snapshot.png" 2>/dev/null | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$D/build/snapshot.png" 2>/dev/null | awk '/pixelHeight/{print $2}')
  [ $rc -eq 0 ] && [ "$w" = 640 ] && [ "$h" = 320 ] && ok "[$placement] snapshot 640x320" || ng "[$placement] snapshot" "rc=$rc ${w}x${h}"
  mline="$(grep '^menubar: ' <<<"$snap")"
  if [ "$placement" = desktop ]; then
    [ -z "$mline" ] && ok "[$placement] 沒有 menubar: 行" || ng "[$placement] 不該有 menubar: 行" "$mline"
  else
    txt="${mline#menubar: }"
    n=$(sed -n 's/^menubar-length: //p' <<<"$snap")
    [ -n "$n" ] || n=99
    [ -n "$mline" ] && [ -n "$txt" ] && [ "$n" -le 12 ] && ok "[$placement] menubar: 文字「${txt}」(${n} 字)" || ng "[$placement] menubar: 行" "$mline"
  fi

  err="$(bash "$S/snapshot.sh" "$D" --error 2>&1)"; rc=$?
  [ $rc -eq 0 ] && [ -f "$D/build/snapshot-error.png" ] && grep -q '無資料:模擬錯誤' <<<"$err" && ok "[$placement] 錯誤預覽" || ng "[$placement] 錯誤預覽" "$err"

  sc="$("$BIN" --self-check 2>&1)"; rc=$?
  good=1
  [ $rc -eq 0 ] || good=0
  grep -q "^placement: $placement$" <<<"$sc" || good=0
  if [ "$placement" != menubar ]; then
    lv=$(sed -nE 's/^window: level=(-?[0-9]+) expected=(-?[0-9]+).*/\1 \2/p' <<<"$sc")
    [ -n "$lv" ] && [ "${lv% *}" = "${lv#* }" ] || good=0
  else
    grep -q '^window:' <<<"$sc" && good=0
  fi
  if [ "$placement" != desktop ]; then grep -q '^statusItem: .' <<<"$sc" || good=0; else grep -q '^statusItem:' <<<"$sc" && good=0; fi
  [ $good -eq 1 ] && ok "[$placement] --self-check" || ng "[$placement] --self-check" "$(tr '\n' '|' <<<"$sc")"
done

# self-check 不寫 state.json
[ ! -e "$D/state.json" ] && ok "--self-check 未寫 state.json" || ng "--self-check 寫了 state.json"

# 骨架 diff:排除 4 個可改檔案、build/、state.json
d="$(diff -r "$KIT/template" "$D" -x build -x state.json -x Widget.swift -x Provider.swift -x widget.json -x README.md 2>&1)"
[ -z "$d" ] && ok "骨架 diff 無差異" || ng "骨架 diff" "$d"

# 一般預覽取資料失敗時 snapshot 結束碼為 3
WIDGET_FORCE_ERROR=1 bash "$S/snapshot.sh" "$D" >/dev/null 2>&1; rc=$?
[ $rc -eq 3 ] && ok "取資料失敗時 snapshot 結束碼 3" || ng "取資料失敗時 snapshot 結束碼" "rc=$rc"

# 錯誤模擬環境變數
if WIDGET_FORCE_ERROR=1 "$BIN" --once >/dev/null 2>&1; then ng "WIDGET_FORCE_ERROR=1 時 --once 要失敗"; else ok "WIDGET_FORCE_ERROR=1 時 --once 失敗"; fi

# widget.json 有打包進 bundle(外接磁碟上 GUI 啟動讀不到專案資料夾)
RES="$(dirname "$BIN")/../Resources/widget.json"
cmp -s "$RES" "$D/widget.json" && ok "widget.json 已打包進 bundle" || ng "widget.json 未打包進 bundle" "$RES"

# 找不到 widget.json:專案與 bundle 內都改名後 --once 要失敗並說明原因
mv "$D/widget.json" "$D/widget.json.bak"; mv "$RES" "$RES.bak"
msg="$("$BIN" --once 2>&1)"; rc=$?
mv "$D/widget.json.bak" "$D/widget.json"; mv "$RES.bak" "$RES"
[ $rc -ne 0 ] && grep -q '找不到 widget.json' <<<"$msg" && ok "找不到 widget.json 時 --once 失敗" || ng "找不到 widget.json" "rc=$rc $msg"

# 單一實例:instance.lock 被別的程序鎖住時,常駐模式要直接結束(結束碼 0),不開第二個視窗
SUP="$HOME/Library/Application Support/com.widget.t-sample"
if [ -e "$SUP" ] && [ -n "$(ls -A "$SUP" 2>/dev/null)" ]; then echo "SKIP  單一實例($SUP 已有資料,不動它)"; else
mkdir -p "$SUP"
perl -e 'use Fcntl ":flock"; open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; print "locked\n"; $| = 1; sleep 30' "$SUP/instance.lock" > "$TMP/lock.out" &
LOCKPID=$!
for _ in $(seq 1 50); do grep -q locked "$TMP/lock.out" 2>/dev/null && break; sleep 0.1; done
"$BIN" > "$TMP/dup.out" 2>&1 &
DUP=$!
for _ in $(seq 1 50); do kill -0 $DUP 2>/dev/null || break; sleep 0.1; done
if kill -0 $DUP 2>/dev/null; then kill $DUP; wait $DUP 2>/dev/null; ng "單一實例:已有實例時要直接結束" "5 秒內沒有結束"
else wait $DUP; rc=$?; [ $rc -eq 0 ] && grep -q '已有一個 t-sample 在執行' "$TMP/dup.out" && ok "單一實例:已有實例時直接結束(結束碼 0)" || ng "單一實例" "rc=$rc $(cat "$TMP/dup.out")"; fi
kill $LOCKPID 2>/dev/null; wait $LOCKPID 2>/dev/null; LOCKPID=""; DUP=""
rm -rf "$SUP"
fi

echo "----"
echo "通過 $pass,失敗 $fail"
[ $fail -eq 0 ]
