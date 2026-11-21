#!/bin/bash
# stack-go 自我測試:建立骨架 → vet / build / test → contract-check(合法、3.1、壞檔)→ planned 規則。
# 需要 Go >= 1.26 與網路(Go module proxy);沒有 go 時印 SKIP。測完刪除暫存目錄。
set -uo pipefail
SKILL="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$(cd "$SKILL/../web-dev-kit" && pwd)"
source "$SKILL/scripts/versions.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /' | head -20; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }

if ! go_ok; then
  skip "全部:需要 Go >= $GO_MIN"
  echo "---"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; exit 0
fi

WORK="$(mktemp -d)"; export WEB_DEV_KIT_TMP="$WORK/kit"
trap 'bash "$KIT/scripts/stop.sh" t-go >/dev/null 2>&1; chmod -R u+w "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
P="$WORK/shop"; mkdir -p "$P"

out="$(bash "$SKILL/scripts/new-backend.sh" "$P" 2>&1)" && ok "new-backend:建立骨架" || bad "new-backend" "$out"
cd "$P/backend" || exit 1
[ -z "$(gofmt -l .)" ] && ok "gofmt:無輸出" || bad "gofmt" "$(gofmt -l .)"
out="$(go vet ./... 2>&1)" && ok "go vet" || bad "go vet" "$out"
out="$(go build ./... 2>&1)" && ok "go build" || bad "go build" "$out"
out="$(go test ./... 2>&1)" && ok "go test(契約 + migration + healthz)" || bad "go test" "$out"
out="$(go mod tidy -diff 2>&1)" && ok "go mod tidy -diff:無差異" || bad "tidy -diff" "$out"

out="$(bash "$SKILL/scripts/contract-check.sh" t-cc "$P/api/openapi.yaml")"
[ "$out" = "valid" ] && ok "contract-check:骨架契約 valid" || bad "contract-check:valid" "$out"
sed 's/^openapi: 3.0.3/openapi: 3.1.0/' "$P/api/openapi.yaml" > "$WORK/v31.yaml"
out="$(bash "$SKILL/scripts/contract-check.sh" t-cc "$WORK/v31.yaml")"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "3.0.x" && ok "contract-check:拒絕 3.1" || bad "contract-check:3.1" "$out"
printf 'openapi: 3.0.3\ninfo: {title: x}\npaths: {}\n' > "$WORK/bad.yaml"
out="$(bash "$SKILL/scripts/contract-check.sh" t-cc "$WORK/bad.yaml")"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "validate error" && ok "contract-check:缺 info.version 判失敗" || bad "contract-check:bad" "$out"

# 契約多一個沒標 planned 的端點 → 契約測試失敗;標 planned 後通過
cp "$P/api/openapi.yaml" "$WORK/orig.yaml"
python3 - "$P/api/openapi.yaml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("paths:\n", "paths:\n  /api/items:\n    get:\n      operationId: listItems\n      responses:\n        \"200\":\n          description: OK\n",1)
open(p,"w").write(s)
PY
out="$(go test ./internal/httpapi/ -run TestContractRoutes 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "GET /api/items" && ok "契約測試:多出未實作端點時失敗" || bad "契約測試:未實作" "$out"
python3 - "$P/api/openapi.yaml" <<'PY'
import sys
p=sys.argv[1]; s=open(p).read()
s=s.replace("      operationId: listItems\n","      operationId: listItems\n      x-status: planned\n",1)
open(p,"w").write(s)
PY
out="$(go test ./internal/httpapi/ -run TestContractRoutes 2>&1)" && ok "契約測試:x-status planned 時通過" || bad "契約測試:planned" "$out"
cp "$WORK/orig.yaml" "$P/api/openapi.yaml"

# 回應不符契約時 Do() 要失敗:把 healthz 回傳改成 {"status":"bad"}
sed -i '' 's/"status": "ok"/"status": "bad"/' internal/httpapi/routes.go
out="$(go test ./internal/httpapi/ -run TestHealthz 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "does not match contract" && ok "Do():回應不符契約時失敗" || bad "Do():回應驗證" "$out"
sed -i '' 's/"status": "bad"/"status": "ok"/' internal/httpapi/routes.go

# healthcheck 子命令(容器 HEALTHCHECK 用):伺服器在跑時 0,沒在跑時 1
SRV="$WORK/kit/server"; mkdir -p "$WORK/kit"
out="$(go build -o "$SRV" ./cmd/server 2>&1)" && ok "go build -o server" || bad "go build -o" "$out"
RUNDIR="$WORK/run"; mkdir -p "$RUNDIR"
out="$(bash "$KIT/scripts/serve.sh" t-go "$RUNDIR" 18080 --health /healthz -- "$SRV" 2>&1)" || bad "serve server" "$out"
GP="$(echo "$out" | sed -n 's/.*port=\([0-9]*\).*/\1/p')"
[ -f "$RUNDIR/data/dev.db" ] && ok "沒設 DATABASE_URL:在工作目錄建 data/dev.db" || bad "預設 SQLite" "$(ls -R "$RUNDIR")"
PORT="$GP" "$SRV" healthcheck && ok "healthcheck:伺服器在跑時結束碼 0" || bad "healthcheck:在跑" "port=$GP"
bash "$KIT/scripts/stop.sh" t-go >/dev/null
out="$(PORT="$GP" "$SRV" healthcheck 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "healthcheck:沒在跑時結束碼 1" || bad "healthcheck:沒在跑" "rc=$rc $out"
# 工作目錄不可寫(像 distroless 的 /)且沒設 DATABASE_URL:清楚的錯誤,不是 panic
RO="$WORK/ro"; mkdir -p "$RO"; chmod 555 "$RO"
out="$(cd "$RO" && env -u DATABASE_URL PORT="$GP" "$SRV" 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "set DATABASE_URL or run from a writable directory" && ! echo "$out" | grep -q panic && ok "唯讀工作目錄:清楚錯誤並結束碼 1" || bad "唯讀工作目錄" "rc=$rc $out"
chmod 755 "$RO"
grep -q "gcr.io/distroless/static-debian12:nonroot" Dockerfile && grep -q "CGO_ENABLED=0" Dockerfile && grep -q "golang:$GO_MIN-alpine" Dockerfile \
  && ok "Dockerfile:多階段、CGO_ENABLED=0、distroless nonroot、Go 版本 = GO_MIN" || bad "Dockerfile" "$(cat Dockerfile)"

# 情境子測試的 -run 寫法(integration-verifier 用)
cat > internal/httpapi/scenario_test.go <<'EOF'
package httpapi

import "testing"

func TestScenarioNaming(t *testing.T) {
	t.Run("LOGIN-S2: wrong password returns 401", func(t *testing.T) {})
}
EOF
out="$(go test ./... -run '/^[A-Z]+-S[0-9]+:' -v 2>&1)"
echo "$out" | grep -q -- "--- PASS: TestScenarioNaming/LOGIN-S2:_wrong_password_returns_401" && ok "-run '/^[A-Z]+-S[0-9]+:' 抓得到情境子測試" || bad "情境 -run" "$out"
rm internal/httpapi/scenario_test.go

# 在 git worktree 裡建骨架:模組名要取主 repo 目錄名,不是 worktree 目錄名(2026-11-21 得到 example.com/backend/backend)
M="$WORK/myshop"; mkdir -p "$M"
git -C "$M" init -q && git -C "$M" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git -C "$M" worktree add -q -b wt-test "$WORK/wt/backend" 2>/dev/null
out="$(bash "$SKILL/scripts/new-backend.sh" "$WORK/wt/backend" 2>&1)"
mod="$(head -1 "$WORK/wt/backend/backend/go.mod" 2>/dev/null)"
[ "$mod" = "module example.com/myshop/backend" ] && ok "new-backend:worktree 內模組名取主 repo 名" || bad "new-backend:worktree 模組名" "$mod / $out"
git -C "$M" worktree remove --force "$WORK/wt/backend" 2>/dev/null

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
