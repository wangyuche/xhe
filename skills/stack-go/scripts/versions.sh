# stack-go 固定的依賴版本與最低 Go 版本(由其他腳本 source)。
# 版本依 proxy.golang.org 2026-11-16 查得的最新版;更新時同步改 SKILL.md 與 tests。
GO_MIN="1.26"                                  # 也是 template/backend/Dockerfile 的 golang:<GO_MIN>-alpine
DEP_KIN_OPENAPI="github.com/getkin/kin-openapi@v0.153.0"   # go 1.25
DEP_GOOSE="github.com/pressly/goose/v3@v3.30.1"            # go 1.26.0
DEP_SQLITE="modernc.org/sqlite@v1.62.0"                    # go 1.26.0
DEP_PGX="github.com/jackc/pgx/v5@v5.13.0"                  # go 1.25.0
export GOTOOLCHAIN=local

# go version 是否 >= GO_MIN(結束碼 0 = 夠新)
go_ok() {
  command -v go >/dev/null 2>&1 || return 1
  local v; v="$(go env GOVERSION 2>/dev/null | sed 's/^go//')"
  [ "$(printf '%s\n%s\n' "$GO_MIN" "$v" | sort -V | head -1)" = "$GO_MIN" ]
}
