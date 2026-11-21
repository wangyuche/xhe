#!/bin/bash
# 用法:update-skeleton.sh <dir>
# 把既有 widget 的骨架檔(4 個可改檔案以外)更新成目前 kit 的 template。修改流程一開始執行,
# 舊版 kit 建立的 widget 才能通過骨架 diff,也才會拿到新骨架的修正(例如單一實例鎖)。
# 不動 Widget.swift、Provider.swift、widget.json、README.md、build/。印出更新了哪些檔案。
source "$(dirname "$0")/_common.sh"
load_widget "$@"
updated=()
for f in "$SKILL_DIR/template"/*; do
  b="$(basename "$f")"
  case "$b" in Widget.swift|Provider.swift|widget.json|README.md) continue ;; esac
  if ! cmp -s "$f" "$WIDGET_DIR/$b"; then cp "$f" "$WIDGET_DIR/$b"; updated+=("$b"); fi
done
# template 已經沒有的骨架檔(kit 改名或移除)也要刪,否則骨架 diff 不會過、可能重複定義
removed=()
for f in "$WIDGET_DIR"/*.swift; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  case "$b" in Widget.swift|Provider.swift) continue ;; esac
  [ -e "$SKILL_DIR/template/$b" ] || { rm "$f"; removed+=("$b"); }
done
[ ${#removed[@]} -gt 0 ] && echo "已移除 template 沒有的骨架檔:${removed[*]}"
if [ ${#updated[@]} -eq 0 ] && [ ${#removed[@]} -eq 0 ]; then echo "骨架已是最新"; exit 0; fi
if [ ${#updated[@]} -eq 0 ]; then echo "骨架已是最新"; else echo "已更新骨架:${updated[*]}(要重新 build)"; fi
