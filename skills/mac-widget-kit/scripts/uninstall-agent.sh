#!/bin/bash
# 用法:uninstall-agent.sh <dir>
# 移除開機自動啟動並停止該 widget。
source "$(dirname "$0")/_common.sh"
load_widget "$@"
plist="$HOME/Library/LaunchAgents/$LABEL.plist"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if [ -f "$plist" ]; then rm "$plist"; echo "已移除:$plist"; else echo "沒有安裝:$plist"; fi
