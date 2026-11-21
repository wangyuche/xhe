---
name: stack-nextjs
description: Next.js 16(App Router、TypeScript)前端規則與骨架:執行時轉發後端(src/proxy.ts 讀 BACKEND_URL)、standalone 輸出與 Dockerfile、Server / Client Component 呼叫後端與 session cookie 轉送、從 OpenAPI 契約產生型別、Prism 契約 mock、Vitest 與 Playwright(channel chrome)設定、驗證順序。frontend-owner 寫前端時使用;碰到 next.config 或 app/ 下的 ts / tsx 時也適用。
paths: ["**/next.config.*", "**/app/**/*.tsx", "**/app/**/*.ts"]
---

# stack-nextjs

`<skill>` = 這個 skill 的目錄。下文 `<pm>` = lockfile 對應的套件管理器(沒有 lockfile 用 npm)。

## 版本
- Node.js ≥ **24.18**(Prism 5.16 要求)。不足時回 BLOCKED,附 `brew install node` / `brew upgrade node`(由使用者執行)。
- 固定版本見 `scripts/versions.sh`:create-next-app / next 16.4.6、vitest 5.1、Playwright 1.65、openapi-typescript 7.13、openapi-fetch 0.17、Prism 5.16。

## 新專案
```bash
bash <skill>/scripts/new-frontend.sh <專案根目錄> [--frontend frontend] [--api api]
```
建立後已有:`next.config.ts`(`output: "standalone"`)、`src/proxy.ts`(轉發 `/api/*`)、`src/lib/backend.ts`、`vitest.config.ts`(排除 `e2e/**`)、`playwright.config.ts`、`e2e/smoke.spec.ts`、`src/lib/api/{client,server,schema.d}.ts`、`Dockerfile`、`.dockerignore`,以及 scripts `postbuild`(複製 static / public 進 `.next/standalone`)、`start`(`node .next/standalone/server.js`)、`test`、`test:e2e`、`gen:api`、`mock:api`。

## 規則
1. **呼叫後端**
   - Client Component:`import { api } from "@/lib/api/client"`,打相對路徑 `/api/...`(`src/proxy.ts` 轉發,session cookie 同源自動帶)。
   - Server Component / Route Handler:`const api = await serverApi()`(`@/lib/api/server`),它會 `await connection()`(動態渲染,build 時不打 API)並把 `cookies()` 轉成 `Cookie` header 轉送。
   - 不用 `NEXT_PUBLIC_*` 放後端網址或任何秘密。不在 Route Handler / Server Action 寫業務邏輯或連資料庫,只能轉發。
2. **後端網址(執行時讀取)**:`src/proxy.ts` 對每個 `/api/*` 請求讀 `BACKEND_URL`,沒設用 `API_PROXY_TARGET`,兩者都沒設回 503 `{"error":{"code":"backend_not_configured",…}}`;`serverApi()` 用同一個 `backendUrl()`。值只在**啟動**時帶(`serve.sh --env BACKEND_URL=…` 或 compose `environment`),build 不需要、也不會寫死,所以同一個 build / 映像可接任何後端。不要再加 `next.config` 的 `rewrites`(build 時就固定)。三種情況:
   1. 簡報給了後端網址 → 用它。
   2. 有契約、沒網址 → `serve.sh <name>-mock <前端目錄> 4010 -- <pm> run mock:api`,`BACKEND_URL` 指向它(Prism 只回範例、不保存狀態)。
   3. 沒契約或缺端點 → 回 ISSUES 附契約變更請求;只有簡報說「先用 mock 做純畫面」時讀 `src/mocks/` 本地資料。
3. **型別**:有契約就先 `<pm> run gen:api`;API 型別一律來自 `src/lib/api/schema.d.ts`(由 `openapi-fetch` 的 `paths` 推得),不手寫。
4. **Server / Client Component**:預設 Server Component;需要 state、事件、瀏覽器 API 才加 `"use client"`,而且放在最小的葉節點。頁面 metadata 用 `export const metadata` / `generateMetadata`。
5. **E2E**(`e2e/*.spec.ts`):每個測試自己建資料(UI 或 `/api`),用唯一值(`Date.now()`)避免互撞;驗收情境測試名稱以「編號 + 冒號」開頭。`playwright.config.ts` 沒設 `E2E_BASE_URL` / `E2E_OUTPUT_DIR` 會直接報錯(`--list` 除外)。
6. **登入**:後端發 HttpOnly session cookie,前端不在 JS 存 token。截圖要登入的頁面用 `shot.mjs --cookie session=test-…` 或 `--cookie-jar`。

7. **正式建置**:`output: "standalone"`。`<pm> run build` 後由 `postbuild` 把 `.next/static`、`public` 複製進 `.next/standalone`;`<pm> start` = `node .next/standalone/server.js`(讀 `PORT`、`HOSTNAME`)。不要用 `next start`(standalone 下會警告且不保證可用)。`postbuild` 是 npm 的 post-hook;用 pnpm 時要開 `enable-pre-post-scripts` 或 build 後自己跑一次。

## Docker(本機開發一律用 Docker 跑整個網站時)
- `Dockerfile`:`node:24-alpine` 三階段(`npm ci` → `npm run build` → 只複製 `.next/standalone`),以 `node` 使用者執行,`PORT=3000`、`HOSTNAME=0.0.0.0`,`HEALTHCHECK` 用 `node -e fetch(...)` 打 `/`(狀態 < 500 算健康)。
- `src/lib/api/schema.d.ts` 要提交:契約 `../api/openapi.yaml` 在 build context 之外,映像裡不跑 `gen:api`。改契約後先在本機 `gen:api` 再 build。
- compose 裡 `environment: BACKEND_URL: http://backend:8080`,只有前端對外開埠(範例:web-dev-kit `templates/docker-compose.yml`)。啟停只透過 web-dev-kit `compose.sh`,不直接 `docker run` / `docker compose`。

## 驗證順序(frontend-owner)
```bash
<pm> run lint
<pm> run build                         # 不需要後端網址;產生 .next/standalone
npx tsc --noEmit                       # build 之後(路由型別才已產生)
node_modules/.bin/vitest run --reporter=verbose
# (需要時)serve.sh <name>-mock … -- <pm> run mock:api
# serve.sh <name> <前端目錄> 3000 --env BACKEND_URL=… -- node_modules/.bin/next dev -p {port}
# 正式建置:serve.sh <name> <前端目錄> 3000 --env BACKEND_URL=… -- <pm> run -s start
# shot.mjs 桌面 / 手機
node_modules/.bin/playwright test --list
E2E_BASE_URL=<url> E2E_OUTPUT_DIR=<tmp>/<name>/e2e <pm> run test:e2e
# 檢查 server.log → stop.sh(dev 與 mock)→ scope.sh check → secret-scan.sh
```
