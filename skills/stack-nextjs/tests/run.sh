#!/bin/bash
# stack-nextjs 自我測試:建立前端 → lint / build / tsc / vitest → gen:api → Prism mock + next dev + rewrites →
# playwright --list 與 smoke。需要 Node >= 24.18、網路(npm)、Google Chrome;沒有 node 時印 SKIP。測完刪除暫存目錄。
set -uo pipefail
SKILL="$(cd "$(dirname "$0")/.." && pwd)"
KIT="$(cd "$SKILL/../web-dev-kit" && pwd)"
source "$SKILL/scripts/versions.sh"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | sed 's/^/      /' | tail -20; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }

if ! node_ok; then
  skip "全部:需要 Node.js >= $NODE_MIN"
  echo "---"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; exit 0
fi

WORK="$(mktemp -d)"; export WEB_DEV_KIT_TMP="$WORK/kit"
cleanup() { bash "$KIT/scripts/stop.sh" t-fe >/dev/null 2>&1; bash "$KIT/scripts/stop.sh" t-mock >/dev/null 2>&1; rm -rf "$WORK"; }
trap cleanup EXIT
export NEXT_TELEMETRY_DISABLED=1
P="$WORK/shop"; mkdir -p "$P/api"
cat > "$P/api/openapi.yaml" <<'EOF'
openapi: 3.0.3
info: {title: shop, version: 0.1.0}
paths:
  /api/items:
    get:
      operationId: listItems
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema:
                type: object
                required: [items]
                properties:
                  items:
                    type: array
                    items: {type: object, required: [id, name], properties: {id: {type: integer}, name: {type: string}}}
              example: {items: [{id: 1, name: apple}]}
EOF

out="$(bash "$SKILL/scripts/new-frontend.sh" "$P" 2>&1)" && ok "new-frontend:建立" || { bad "new-frontend" "$out"; echo "---"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; exit 1; }
cd "$P/frontend" || exit 1
grep -q '"listItems"\|"/api/items"' src/lib/api/schema.d.ts && ok "gen:api:由契約產生型別" || bad "gen:api" "$(head -20 src/lib/api/schema.d.ts)"
out="$(npm run -s lint 2>&1)" && ok "lint" || bad "lint" "$out"
out="$(npm run -s build 2>&1)" && ok "build(沒設 API_PROXY_TARGET 也能 build)" || bad "build" "$out"
out="$(npx tsc --noEmit 2>&1)" && ok "tsc --noEmit" || bad "tsc" "$out"
out="$(node_modules/.bin/vitest run --reporter=verbose 2>&1)"; rc=$?
# 骨架沒有元件測試:vitest 找不到測試檔時結束碼 1,但不能跑到 e2e/
if ! echo "$out" | grep -q "smoke.spec"; then ok "vitest:不會跑 e2e/"; else bad "vitest:跑到 e2e" "$out"; fi
out="$(node_modules/.bin/playwright test --list 2>&1)" && echo "$out" | grep -q "smoke: home page loads" && ok "playwright --list(不需 env)" || bad "playwright --list" "$out"
out="$(node_modules/.bin/playwright test 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "E2E_BASE_URL is required" && ok "playwright:沒設 env 時報錯" || bad "playwright env" "$out"

M="$(bash "$KIT/scripts/serve.sh" t-mock "$P/frontend" 4010 --health /api/items -- npm run -s mock:api 2>&1)" && ok "mock:api(Prism)啟動" || bad "mock:api" "$M"
MURL="$(echo "$M" | sed -n 's/^url=\([^ ]*\).*/\1/p')"
D="$(bash "$KIT/scripts/serve.sh" t-fe "$P/frontend" 3000 --timeout 120 --env API_PROXY_TARGET="$MURL" -- node_modules/.bin/next dev -p '{port}' 2>&1)" && ok "next dev 啟動" || bad "next dev" "$D"
FURL="$(echo "$D" | sed -n 's/^url=\([^ ]*\).*/\1/p')"
body="$(curl -s "$FURL/api/items")"
echo "$body" | grep -q '"apple"' && ok "rewrites:/api/* 轉發到 mock" || bad "rewrites" "$body"
out="$(E2E_BASE_URL="$FURL" E2E_OUTPUT_DIR="$WORK/e2e" npm run -s test:e2e 2>&1)" && ok "playwright smoke(channel chrome)" || bad "playwright smoke" "$out"
[ ! -d test-results ] && [ ! -d playwright-report ] && ok "playwright 沒有寫進專案目錄" || bad "playwright 輸出位置" "$(ls)"
bash "$KIT/scripts/stop.sh" t-fe >/dev/null; bash "$KIT/scripts/stop.sh" t-mock >/dev/null

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
