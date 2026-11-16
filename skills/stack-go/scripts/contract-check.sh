#!/bin/bash
# 用法:contract-check.sh <name> <openapi.yaml>
# 在暫存目錄自帶 go.mod,用 kin-openapi 載入並驗證契約(必須是 OpenAPI 3.0.x)。不寫進專案。
# 輸出 valid(結束碼 0)或錯誤(結束碼 1)。go 不存在或版本不足:結束碼 3。
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
source "$DIR/versions.sh"

[ $# -eq 2 ] || { echo "用法:contract-check.sh <name> <openapi.yaml>" >&2; exit 2; }
NAME="$1"; SPEC="$2"
case "$NAME" in *[!a-z0-9-]*|'') echo "錯誤:<name> 只能是小寫英文、數字與連字號" >&2; exit 2 ;; esac
[ -f "$SPEC" ] || { echo "錯誤:找不到契約 $SPEC" >&2; exit 1; }
SPEC_ABS="$(cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")"
go_ok || { echo "錯誤:需要 Go >= $GO_MIN(brew install go 或 brew upgrade go,由使用者執行)" >&2; exit 3; }

TMP="${WEB_DEV_KIT_TMP:-${TMPDIR:-/tmp}/web-dev-kit}"; TMP="${TMP%/}"
WORK="$TMP/$NAME/contract-check"
mkdir -p "$WORK"
if [ ! -x "$WORK/contract-check" ] || ! grep -q "${DEP_KIN_OPENAPI#*@}" "$WORK/go.mod" 2>/dev/null; then
  rm -rf "$WORK"/*
  cat > "$WORK/main.go" <<'GO'
package main

import (
	"fmt"
	"os"
	"strings"

	"github.com/getkin/kin-openapi/openapi3"
)

func main() {
	loader := openapi3.NewLoader()
	doc, err := loader.LoadFromFile(os.Args[1])
	if err != nil {
		fmt.Println("load error:", err)
		os.Exit(1)
	}
	if !strings.HasPrefix(doc.OpenAPI, "3.0") {
		fmt.Printf("version error: openapi must be 3.0.x, got %q\n", doc.OpenAPI)
		os.Exit(1)
	}
	if err := doc.Validate(loader.Context); err != nil {
		fmt.Println("validate error:", err)
		os.Exit(1)
	}
	fmt.Println("valid")
}
GO
  ( cd "$WORK" && go mod init contractcheck >/dev/null 2>&1 && go get "$DEP_KIN_OPENAPI" >/dev/null 2>&1 && go mod tidy >/dev/null 2>&1 ) \
    || { echo "錯誤:下載 $DEP_KIN_OPENAPI 失敗(需要連 Go module proxy)" >&2; exit 1; }
  ( cd "$WORK" && go build -o contract-check . ) || exit 1
fi
"$WORK/contract-check" "$SPEC_ABS"
