#!/bin/bash
# 用法:new-widget.sh <name> <dir>
# 從骨架建立新的 widget 專案。name 為小寫英文、數字、連字號;目錄已存在則失敗。
source "$(dirname "$0")/_common.sh"
[ $# -eq 2 ] || die "用法:new-widget.sh <name> <dir>"
name="$1"; dir="$2"
[[ "$name" =~ ^[a-z][a-z0-9]*(-[a-z0-9]+)*$ ]] || die "名稱只能用小寫英文、數字、連字號,且以英文開頭:$name"
app="$(pascal "$name")"
[ ${#app} -le 16 ] || die "名稱太長:app 名稱 $app 超過 16 字元(macOS 程序名稱 p_comm 上限 16;腳本用 pgrep / pkill -x 找程序,保守限制),請用較短的名稱"
[ -e "$dir" ] && die "目錄已存在:$dir(新建請換一個名稱或目錄)"
mkdir -p "$(dirname "$dir")"
cp -R "$SKILL_DIR/template" "$dir"
sed -i '' -e "s/\"name\": \"\"/\"name\": \"$name\"/" -e "s/\"displayName\": \"\"/\"displayName\": \"$name\"/" "$dir/widget.json"
echo "已建立:$(cd "$dir" && pwd)"
echo "可改檔案:Widget.swift、Provider.swift、widget.json、README.md"
