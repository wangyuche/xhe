#!/bin/bash
# 用法:uninstall-agent.sh <dir>
# 移除開機自動啟動並停止該 widget。
source "$(dirname "$0")/_common.sh"
load_widget "$@"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
# 手動 open 的實例不歸 launchd 管,bootout 停不到
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -x "$APP_NAME" || true
  for _ in $(seq 1 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
  pgrep -x "$APP_NAME" >/dev/null && echo "警告:$APP_NAME 仍在執行,請手動結束" >&2
fi
if [ -f "$plist" ]; then rm "$plist"; echo "已移除:$plist"; else echo "沒有安裝:$plist"; fi
