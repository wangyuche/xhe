#!/bin/bash
# 用法:new-backend.sh <專案根目錄> [--module <模組名>] [--backend <目錄>] [--api <目錄>]
# 從 template/ 建立 Go 後端骨架(路由表、/healthz、契約測試、goose migration、.env.example)。
# 後端目錄已存在且非空時失敗。契約已存在時不覆蓋(要自己確認有 /healthz 與 Error schema)。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$DIR/.." && pwd)"
source "$DIR/versions.sh"

[ $# -ge 1 ] || { echo "用法:new-backend.sh <專案根目錄> [--module <模組名>] [--backend backend] [--api api]" >&2; exit 2; }
ROOT="$(cd "$1" && pwd -P)"; shift
BACKEND="backend"; API="api"; MODULE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --module) MODULE="$2"; shift 2 ;;
    --backend) BACKEND="${2%/}"; shift 2 ;;
    --api) API="${2%/}"; shift 2 ;;
    *) echo "未知參數:$1" >&2; exit 2 ;;
  esac
done
# 專案名取主 repo 目錄名:在 git worktree 裡 basename "$ROOT" 會是 worktree 目錄名(例如 backend),
# 得到 example.com/backend/backend(2026-11-21 fortest)。git common dir 的上層才是主 repo。
PROJ_DIR="$ROOT"
if COMMON="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  case "$COMMON" in */.git) PROJ_DIR="$(dirname "$COMMON")" ;; esac
fi
PROJ="$(basename "$PROJ_DIR" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9-]/-/g')"
[ -n "$MODULE" ] || MODULE="example.com/$PROJ/backend"
go_ok || { echo "錯誤:需要 Go >= $GO_MIN(brew install go 或 brew upgrade go,由使用者執行)" >&2; exit 3; }

B="$ROOT/$BACKEND"
if [ -d "$B" ] && [ -n "$(ls -A "$B" 2>/dev/null)" ]; then
  echo "錯誤:$B 已存在且不是空的" >&2; exit 1
fi
mkdir -p "$B"
cp -R "$SKILL/template/backend/." "$B/"
find "$B" -name '*.go' -exec sed -i '' "s#__MODULE__#$MODULE#g" {} +

CONTRACT_NOTE="新建"
if [ -f "$ROOT/$API/openapi.yaml" ]; then
  CONTRACT_NOTE="已存在,未覆蓋"
else
  mkdir -p "$ROOT/$API"
  sed "s#__PROJECT__#$PROJ#g" "$SKILL/template/api/openapi.yaml" > "$ROOT/$API/openapi.yaml"
fi
# 契約測試預設路徑是 <repo>/api/openapi.yaml;不同位置時改測試裡的預設值
REL="$(python3 -c 'import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))' "$ROOT/$API/openapi.yaml" "$B/internal/httpapi")"
sed -i '' "s#filepath.Join(\"..\", \"..\", \"..\", \"api\", \"openapi.yaml\")#filepath.FromSlash(\"$REL\")#" "$B/internal/httpapi/contract_test.go"

cd "$B"
go mod init "$MODULE" >/dev/null 2>&1
go mod edit -go="$GO_MIN"
go get "$DEP_KIN_OPENAPI" "$DEP_GOOSE" "$DEP_SQLITE" "$DEP_PGX" >/dev/null 2>&1 \
  || { echo "錯誤:下載依賴失敗(需要連 Go module proxy)" >&2; exit 1; }
go mod tidy >/dev/null
echo "已建立 $B(module $MODULE);契約 $ROOT/$API/openapi.yaml:$CONTRACT_NOTE"
