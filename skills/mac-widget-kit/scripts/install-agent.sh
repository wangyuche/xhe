#!/bin/bash
# 用法:install-agent.sh <dir>
# 安裝開機自動啟動(LaunchAgent)。當機會重啟;使用者按「結束」(正常結束)不會被拉起。
source "$(dirname "$0")/_common.sh"
load_widget "$@"
[ -x "$APP_BIN" ] || die "找不到 $APP_BIN,請先執行 build.sh"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
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
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$plist"
echo "已安裝:$plist"
