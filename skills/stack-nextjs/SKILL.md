---
name: stack-nextjs
description: Next.js 16(App Router、TypeScript)前端規則與骨架:轉發後端(API_PROXY_TARGET rewrites)、Server / Client Component 呼叫後端與 session cookie 轉送、從 OpenAPI 契約產生型別、Prism 契約 mock、Vitest 與 Playwright(channel chrome)設定、驗證順序。frontend-owner 寫前端時使用;碰到 next.config 或 app/ 下的 ts / tsx 時也適用。
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
建立後已有:`next.config.ts`(rewrites)、`vitest.config.ts`(排除 `e2e/**`)、`playwright.config.ts`、`e2e/smoke.spec.ts`、`src/lib/api/{client,server,schema.d}.ts`,以及 scripts `test`、`test:e2e`、`gen:api`、`mock:api`。

## 規則
1. **呼叫後端**
   - Client Component:`import { api } from "@/lib/api/client"`,打相對路徑 `/api/...`(rewrites 轉發,session cookie 同源自動帶)。
   - Server Component / Route Handler:`const api = await serverApi()`(`@/lib/api/server`),它會 `await connection()`(動態渲染,build 時不打 API)並把 `cookies()` 轉成 `Cookie` header 轉送。
   - 不用 `NEXT_PUBLIC_*` 放後端網址或任何秘密。不在 Route Handler / Server Action 寫業務邏輯或連資料庫,只能轉發。
2. **`API_PROXY_TARGET` 三種情況**
   1. 簡報給了後端網址 → 用它。
   2. 有契約、沒網址 → `serve.sh <name>-mock <前端目錄> 4010 -- <pm> run mock:api`,`API_PROXY_TARGET` 指向它(Prism 只回範例、不保存狀態)。
   3. 沒契約或缺端點 → 回 ISSUES 附契約變更請求;只有簡報說「先用 mock 做純畫面」時讀 `src/mocks/` 本地資料。
3. **型別**:有契約就先 `<pm> run gen:api`;API 型別一律來自 `src/lib/api/schema.d.ts`(由 `openapi-fetch` 的 `paths` 推得),不手寫。
4. **Server / Client Component**:預設 Server Component;需要 state、事件、瀏覽器 API 才加 `"use client"`,而且放在最小的葉節點。頁面 metadata 用 `export const metadata` / `generateMetadata`。
5. **E2E**(`e2e/*.spec.ts`):每個測試自己建資料(UI 或 `/api`),用唯一值(`Date.now()`)避免互撞;驗收情境測試名稱以「編號 + 冒號」開頭。`playwright.config.ts` 沒設 `E2E_BASE_URL` / `E2E_OUTPUT_DIR` 會直接報錯(`--list` 除外)。
6. **登入**:後端發 HttpOnly session cookie,前端不在 JS 存 token。截圖要登入的頁面用 `shot.mjs --cookie session=test-…` 或 `--cookie-jar`。

## 驗證順序(frontend-owner)
```bash
<pm> run lint
<pm> run build                         # 帶 API_PROXY_TARGET(若有)
npx tsc --noEmit                       # build 之後(路由型別才已產生)
node_modules/.bin/vitest run --reporter=verbose
# (需要時)serve.sh <name>-mock … -- <pm> run mock:api
# serve.sh <name> <前端目錄> 3000 --env API_PROXY_TARGET=… -- node_modules/.bin/next dev -p {port}
# shot.mjs 桌面 / 手機
node_modules/.bin/playwright test --list
E2E_BASE_URL=<url> E2E_OUTPUT_DIR=<tmp>/<name>/e2e <pm> run test:e2e
# 檢查 server.log → stop.sh(dev 與 mock)→ scope.sh check → secret-scan.sh
```
