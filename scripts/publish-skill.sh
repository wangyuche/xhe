#!/usr/bin/env bash
# 把審查過的 agent-forge 發佈到 host 的共用 skill 倉庫。在 host 上執行,不要在沙盒裡跑。
#
# 用法:
#   scripts/publish-skill.sh <共用倉庫路徑> [--ref <git ref>] [--no-fetch]
#
#   <共用倉庫路徑>  host 上掛進沙盒 ~/.claude/skills 的那個資料夾
#   --ref           要發佈的版本,預設 origin/main。回退時給舊的 commit SHA。
#   --no-fetch      不先 git fetch(離線或測試用)
#
# 只取 .claude/skills/agent-forge,先寫到暫存資料夾,驗證後才一次換名替換,
# 執行中的沙盒不會讀到寫了一半的檔案。
set -euo pipefail

SKILL_NAME="agent-forge"
SKILL_PATH=".claude/skills/${SKILL_NAME}"
REF="origin/main"
FETCH=1
STORE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ref) REF="${2:?--ref 需要一個值}"; shift 2 ;;
    --no-fetch) FETCH=0; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "未知的選項:$1" >&2; exit 2 ;;
    *) [ -z "$STORE" ] || { echo "只能給一個共用倉庫路徑" >&2; exit 2; }; STORE="$1"; shift ;;
  esac
done

[ -n "$STORE" ] || { echo "缺少共用倉庫路徑。用法:$0 <共用倉庫路徑> [--ref <ref>]" >&2; exit 2; }
[ -d "$STORE" ] || { echo "共用倉庫不存在:$STORE" >&2; exit 1; }
[ -w "$STORE" ] || { echo "共用倉庫不可寫(你是不是在沙盒裡?):$STORE" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

[ "$FETCH" -eq 0 ] || git fetch --quiet origin

SHA="$(git rev-parse --verify --quiet "${REF}^{commit}")" || { echo "找不到版本:$REF" >&2; exit 1; }
git cat-file -e "${SHA}:${SKILL_PATH}/SKILL.md" 2>/dev/null \
  || { echo "版本 $REF ($SHA) 裡沒有 ${SKILL_PATH}/SKILL.md,可能還沒合併進來" >&2; exit 1; }

TARGET="${STORE}/${SKILL_NAME}"
# 只替換由這個腳本發佈的版本,避免蓋掉別人手動放的同名 skill
if [ -e "$TARGET" ] && [ ! -f "$TARGET/VERSION" ]; then
  echo "$TARGET 已存在但不是這個腳本發佈的(沒有 VERSION),停止。請先確認後手動移走。" >&2
  exit 1
fi

TMP="$(mktemp -d "${STORE}/.${SKILL_NAME}.new.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

git archive "$SHA" "$SKILL_PATH" | tar -x -C "$TMP"
mv "$TMP/$SKILL_PATH" "$TMP/out"
[ -f "$TMP/out/SKILL.md" ] || { echo "解出來的內容沒有 SKILL.md,停止" >&2; exit 1; }

{
  echo "commit: $SHA"
  echo "ref: $REF"
  echo "published: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$TMP/out/VERSION"

OLD=""
if [ -e "$TARGET" ]; then
  OLD="${STORE}/.${SKILL_NAME}.old.$(date +%s)"
  mv "$TARGET" "$OLD"
fi
mv "$TMP/out" "$TARGET"
[ -z "$OLD" ] || rm -rf "$OLD"

echo "已發佈 ${SKILL_NAME} ${SHA} 到 ${TARGET}"
