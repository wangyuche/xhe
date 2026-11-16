#!/bin/bash
# 用法:snapshot.sh <dir> [--error]
# 產生預覽 PNG(2 倍解析度,不需螢幕錄影權限):build/snapshot.png 或 build/snapshot-error.png。
# stdout 印出該次取到的資料;placement 含 menubar 時另印 "menubar: <文字>" 與 "menubar-length: <字數>"。
# 結束碼:0 成功;3 一般預覽但取資料失敗(圖上是錯誤畫面,不算成功預覽)。
source "$(dirname "$0")/_common.sh"
load_widget "${1:-}"
[ -x "$APP_BIN" ] || die "找不到 $APP_BIN,請先執行 build.sh"
if [ "${2:-}" = "--error" ]; then
  out="$WIDGET_DIR/build/snapshot-error.png"
  "$APP_BIN" --snapshot-error "$out"
else
  out="$WIDGET_DIR/build/snapshot.png"
  set +e; "$APP_BIN" --snapshot "$out"; rc=$?; set -e
  echo "預覽圖:$out"
  exit $rc
fi
echo "預覽圖:$out"
