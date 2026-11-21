#!/bin/bash
# 用法:install-agent.sh <dir>
# 安裝開機自動啟動(LaunchAgent)。當機會重啟;使用者按「結束」(正常結束)不會被拉起。
# 安裝時會立刻啟動(RunAtLoad):先停掉手動 open 的同名實例,避免兩個 widget 同時存在。之後不要再另外 open。
source "$(dirname "$0")/_common.sh"
load_widget "$@"
[ -x "$APP_BIN" ] || die "找不到 $APP_BIN,請先執行 build.sh"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME" || true
  for _ in $(seq 1 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
  pgrep -x "$APP_NAME" >/dev/null && die "停不掉執行中的 $APP_NAME,請手動結束後重跑"
  echo "已停止執行中的 $APP_NAME(改由 LaunchAgent 啟動)"
fi
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP_BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST
# bootout 後立刻 bootstrap 偶爾回 5(Input/output error):重試幾次
for i in 1 2 3 4 5; do launchctl bootstrap "gui/$(id -u)" "$plist" 2>"${TMPDIR:-/tmp}/mwk-bootstrap.$$" && { rm -f "${TMPDIR:-/tmp}/mwk-bootstrap.$$"; echo "已安裝並啟動:$plist"; exit 0; }; sleep 1; done
err="$(cat "${TMPDIR:-/tmp}/mwk-bootstrap.$$" 2>/dev/null)"; rm -f "${TMPDIR:-/tmp}/mwk-bootstrap.$$" "$plist"
die "launchctl bootstrap 失敗($err),已移除 $plist;widget 沒有在執行,可用 open \"$APP_PATH\" 手動啟動後再重跑"
