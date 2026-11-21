---
name: stack-go
description: Go 後端規則與骨架(net/http 路由表、OpenAPI 3.0.3 契約測試與回應驗證、goose migration、SQLite / PostgreSQL、錯誤格式、環境變數、session cookie)。backend-owner 寫後端、integration-verifier 驗契約時使用;碰到 .go 或 go.mod 時也適用。
paths: ["**/*.go", "**/go.mod"]
---

# stack-go

`<skill>` = 這個 skill 的目錄。**所有 go 指令都帶 `GOTOOLCHAIN=local`**(不自動下載工具鏈),在後端目錄(`go.mod` 所在處)執行。

## 版本
- Go ≥ **1.26**(goose v3.30、modernc sqlite v1.62 要求)。不足時回 BLOCKED,附 `brew upgrade go`(由使用者執行)。
- 固定依賴(`scripts/versions.sh`):kin-openapi v0.153.0、goose v3.30.1、modernc.org/sqlite v1.62.0、pgx v5.13.0。新增其他依賴前先確認標準庫做不到。

## 腳本
```bash
bash <skill>/scripts/new-backend.sh <專案根目錄> [--module <模組>] [--backend backend] [--api api]   # 新專案骨架
bash <skill>/scripts/contract-check.sh <name> <api/openapi.yaml>                                     # → valid
```

## 目錄結構
```
backend/
  cmd/server/main.go            # 讀環境變數、db.Open(含 migration)、graceful shutdown;`server healthcheck` 子命令
  internal/httpx/httpx.go       # Deps、WriteJSON、WriteError(所有 handler 共用)
  internal/httpapi/routes.go    # Routes() 路由表 —— 唯一註冊點
  internal/httpapi/contract_test.go  # 路由表 ↔ 契約;Do() / DoBadRequest()
  internal/httpapi/<領域>_test.go     # 端點測試(含驗收情境子測試)
  internal/<領域>/              # handler / service / store(例如 internal/auth),只 import httpx
  internal/db/db.go             # Open + goose(embed)
  internal/db/migrations/NNNN_<描述>.sql
  internal/db/migrate_test.go   # 全新 SQLite 上 goose.Up 並檢查欄位
  .env.example  .gitignore(data/、.env)
  Dockerfile  .dockerignore     # 多階段 → distroless static nonroot(見「Docker」)
api/openapi.yaml                # OpenAPI 3.0.3(不用 3.1)
```

## 規則
1. **路由表**:新端點只加在 `Routes()`;handler 放領域套件,簽名 `func(httpx.Deps) http.HandlerFunc`(領域套件只 import `httpx`,`httpapi` import 領域套件,不會循環)。Pattern 用 Go 1.22+ 寫法 `/api/items/{id}`,和契約的 path 寫法相同。
2. **契約同步**:改端點同時改 `api/openapi.yaml`。已定契約但還沒實作的 operation 標 `x-status: planned`;實作完成就拿掉。`TestContractRoutes` 會雙向比對。
3. **錯誤格式**:一律 `httpx.WriteError(w, status, "snake_case_code", "訊息")` → `{"error":{"code","message"}}`,契約裡 4xx / 5xx 都 `$ref: '#/components/schemas/Error'`。
4. **端點測試**:放在 `internal/httpapi/<領域>_test.go`,`h := NewHandler(httpx.Deps{DB: testDB})`。請求符合契約的案例(成功、密碼錯 401、404…)用 `Do(t, h, req)`:請求或回應不符契約就失敗。刻意送不合法請求(缺欄位、型別錯 → 400)用 `DoBadRequest(t, h, req)`:請求必須不符契約,回應仍要符合。service / store 的單元測試放在各自的領域套件。驗收情境的子測試名稱以情境編號加冒號開頭:`t.Run("LOGIN-S2: wrong password returns 401", …)`。
5. **Migration**:goose,檔名 `NNNN_<描述>.sql`,含 `-- +goose Up` / `-- +goose Down`;伺服器啟動時自動 `goose.Up`。新表要在 `migrate_test.go` 的 `want` 加欄位清單。SQL 寫成 SQLite 與 PostgreSQL 都能跑的子集(`INTEGER PRIMARY KEY`、`TEXT`、`TIMESTAMP`;避免 `SERIAL`、`AUTOINCREMENT`)。
6. **測試資料庫**:測試只用 `t.TempDir()` 的 SQLite 或 `file::memory:`,不碰 `data/dev.db`。
6b. **SQLite 並發**:`db.Open` 會對 SQLite DSN 自動補 `_pragma=busy_timeout(5000)` 與 `_txlock=immediate`,不要拿掉;寫入都放在 transaction 裡。`concurrency_test.go` 是回歸測試(2026-11-16 整合驗證發現兩個同時登入其中一個回 500 `SQLITE_BUSY`)。
7. **環境變數**:`PORT`(8080)、`DATABASE_URL`(預設 SQLite `file:data/dev.db?...`;`postgres://` 開頭用 pgx)、`CORS_ORIGINS`(預設 `http://localhost:3000`)、應用程式密鑰(`SESSION_SECRET` 等)。全部列在 `.env.example`,值用 `dev-` 開頭的假值。程式不寫死任何秘密。
8. **登入機制**:後端發 HttpOnly session cookie(`SameSite=Lax`,開發時不設 `Secure`),前端經 Next.js 轉發屬同源。不在 body 回 token 給前端存。
9. **其他**:`log/slog`;`context` 從 request 往下傳;table-driven 測試;不用全域可變狀態(依賴放 `Deps`)。

## Docker(本機開發一律用 Docker 跑整個網站時)
- `Dockerfile`:build 階段 `golang:1.26-alpine`(版本 = `GO_MIN`,改 `versions.sh` 時一起改)、`CGO_ENABLED=0`、`-trimpath`;最終映像 `gcr.io/distroless/static-debian12:nonroot`,只有 `/server`,沒有 Go 工具鏈、shell、curl,以 nonroot 執行,`EXPOSE 8080`。
- **健康檢查**:`/server healthcheck` 打 `http://127.0.0.1:$PORT/healthz`,200 → 結束碼 0,否則 1。Dockerfile 的 `HEALTHCHECK` 與 compose 都用 `["CMD", "/server", "healthcheck"]`(不要寫 curl / wget,映像裡沒有)。
- **資料庫**:compose 裡一律設 `DATABASE_URL=postgres://…@db:5432/…`(範例:web-dev-kit `templates/docker-compose.yml`)。沒設時用相對路徑 SQLite:映像的 `WORKDIR /app` 內有 nonroot 可寫的 `data/`,容器刪掉資料就消失;工作目錄不可寫時 `db.Open` 回清楚錯誤(`set DATABASE_URL or run from a writable directory`)並結束碼 1,不 panic。
- 契約 `api/openapi.yaml` 在 build context(`backend/`)之外,執行期也不需要;不要改成把契約 COPY 進映像。
- 啟停只透過 web-dev-kit `compose.sh`(`-p <專案名>`),不直接 `docker run` / `docker compose`。

## 驗證順序(backend-owner 一般模式)
```bash
cd backend
GOTOOLCHAIN=local go mod tidy && GOTOOLCHAIN=local go mod tidy -diff   # 無輸出
gofmt -l .                                                             # 無輸出
GOTOOLCHAIN=local go vet ./... && GOTOOLCHAIN=local go build ./...
bash <skill>/scripts/contract-check.sh <name> ../api/openapi.yaml      # valid
GOTOOLCHAIN=local go test ./...
GOTOOLCHAIN=local go build -o <tmp>/<name>/server ./cmd/server         # 再交給 web-dev-kit serve.sh --health /healthz
PORT=<port> <tmp>/<name>/server healthcheck                            # 伺服器在跑時結束碼 0
# 有 docker-compose.yml 時:compose.sh build -p <專案名> backend → up → curl → down
```

## 需要時才讀
- `references/concurrency.md`:有 `並發` 類型情境,或端點涉及先檢查再寫入、計數 / 鎖定、不變量、會累積的資料表時(同鎖檢查與寫入、依 key 序列化、清理移出交易 + SKIP LOCKED、有界 context、Hook 交錯測試與反向驗證)。
