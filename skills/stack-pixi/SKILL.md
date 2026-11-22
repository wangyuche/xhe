---
name: stack-pixi
description: PixiJS 8 + Vite 8 + TypeScript 遊戲 / 大廳玩家端的規則(PX-XXX-NN,MUST / SHOULD)與骨架:場景各自 chunk 與 early-boot 白名單、a11y DOM 層(Pixi AccessibilitySystem + 原生 dialog + live region)、i18n、1x / 0.5x AVIF + PNG 素材建置與 KB 預算、效能預算量測(gzip 靜態伺服器 + Slow 4G + 4× CPU)、Playwright 三尺寸 E2E、資源釋放檢查、WebSocket / iframe。game-frontend-owner 寫 Pixi 前端時使用;碰到 import pixi.js 的檔案也適用。MahjongParty 文件引用的 `/pixi-style` 就是這個 skill(編號與意義相同)。
paths: ["**/src/scenes/**/*.ts", "**/src/core/**/*.ts", "**/src/components/**/*.ts", "**/src/assets/**/*.ts", "**/vite.config.ts", "**/tests/e2e/**/*.ts", "**/tests/perf/**/*.ts"]
---

# stack-pixi

`<skill>` = 這個 skill 的目錄;`<project>` = Pixi 專案目錄(有 `package.json` 且依賴 `pixi.js` 8)。

## 規則優先序
1. 專案自己的規則文件(例如 `docs/architecture/code-review-rules/`、budgets 文件、`CLAUDE.md`)比這裡嚴格或專案特有的,照專案;專案的例外條款(EX-n)照它寫的條件。
2. 這裡的 PX 規則:**MUST** 不可違反(違反就是 code review Blocker,退回時引用編號);**SHOULD** 不做要寫理由。
3. 每個專案不同的數值(效能門檻、素材 KB 預算、設計解析度)不寫在規則裡,放專案的 `docs/performance-budgets.md`。
- 編號只能新增、不能改號或改意義(MahjongParty lobby 已引用 ARCH / FMT / LIFE / LOAD / PERF / RES 的編號)。

## 版本
骨架鎖定:pixi.js 8.23.0、vite 8.3.8、typescript 7.0.2、vitest 5.1.1、@playwright/test 1.65.1(`channel: 'chrome'`,用系統 Chrome)、sharp 0.35.5、Node ≥ 22(專案有指定照專案)。`template/package-lock.json` 鎖住全部依賴,`new-pixi.sh` 用 `npm ci`。

## PX 規則

### ARCH 分層
- **PX-ARCH-01(MUST)** 純邏輯層(`src/game/**`、`src/services/**`,專案可擴充)不 import `pixi.js` / `@pixi/*`。檢查:`check-layers.mjs`;骨架另有 `src/game/no-pixi.test.ts`。
- **PX-ARCH-02(MUST)** 對話框、面板、表單用 DOM(原生 `<dialog>` + `showModal()`),焦點與 Esc 交給瀏覽器;不在 Pixi 裡自己畫對話框。

### FMT 格式
- **PX-FMT-01(MUST)** 圖片 AVIF 為主、PNG 備援(不透明的大背景可用 JPG 備援),執行時依支援度選(Pixi `Assets` 的 src 陣列)。
- **PX-FMT-06(SHOULD)** 頻繁變動的數字(分數、計時、滾動)用 `BitmapText`,不用每幀重建貼圖的 `Text`。
- **PX-FMT-07(MUST)** 音訊 ogg(Opus)+ m4a(AAC):`canPlayType('audio/ogg; codecs=opus')` 支援用 ogg,否則 m4a(Safari)。

### LIFE 生命週期
- **PX-LIFE-01(MUST)** 場景 / 物件離開時 `destroy({ children: true })`,並移除自己加的監聽、ticker 回呼、dialog 綁定;貼圖由 `Assets` 管理,不在物件內 destroy。檢查:E2E `cycleLeak`。
- **PX-LIFE-02(MUST)** 全站只有一個 `Application`;stage 下同時只掛一個場景(由 SceneManager 切換)。
- **PX-LIFE-03(MUST)** `webglcontextlost` 要 `preventDefault()` 並顯示錯誤畫面與「重新載入」,不能變白畫面。

### LOAD 載入
- **PX-LOAD-01(MUST)** 程式與素材按場景 / 面板分 chunk 與群組,只從 SceneManager 動態 `import()`;首屏只載 boot 批次(`src/assets/early.ts` 的 `BOOT_GROUPS`)。檢查:`check-early.mjs`(讀 `dist/.vite/manifest.json`)。
- **PX-LOAD-02(MUST)** Vite `assetsInlineLimit: 0`(不內嵌 data URL,Pixi 才能依副檔名與 `@Nx` 判斷);pixi 全部放同一個 chunk(避免它內部的動態 import 在 Slow 4G 下多一輪請求)。
- **PX-LOAD-03(MUST)** 素材檔名帶內容 hash(Vite 預設);檔名中的 `@1x` / `@0.5x` 保留給 Pixi 判斷解析度,不另作他用。
- **PX-LOAD-04(MUST)** `Assets.load` 前查 `Assets.cache.has(alias)`;unload 只 unload 自己載過、cache 裡真的有的 alias;共用貼圖參考計數,歸零才 unload(骨架 `acquireGroup` / `releaseGroup`)。
- **PX-LOAD-05(SHOULD)** 圖片在 Worker 解碼(Pixi 預設 `preferWorkers`);改到主執行緒要在 budgets「例外」寫理由與量測。
- **PX-LOAD-06(MUST)** boot 批次要有傳輸量預算(`boot_kb`,數值在專案 budgets),BGM 不得在第一次手勢前下載;要有啟動量測點(`#loading` 隱藏 = 可互動)。

### PERF 效能
- **PX-PERF-01(MUST)** 效能量測用 production build + gzip 靜態伺服器(`scripts/serve-dist.mjs`;`vite preview` 不壓縮),Slow 4G(latency 562.5 ms、下行 1.44 Mbps、上行 675 kbps)+ 4× CPU、冷快取、每次新 context、5 次取中位數;1920×1080 與 844×390@3x。
- **PX-PERF-02(MUST)** 門檻讀專案 `docs/performance-budgets.md`;「不得退步」的基準是同一份文件的「最新實測」。
- **PX-PERF-03(SHOULD)** 大量重複出現的物件(粒子、飛行物、牌)用物件池,不每次 new / destroy。
- **PX-PERF-04(MUST)** 常駐畫面不用 filter(DropShadow、Blur 等,每個 filter 多一次 render pass);效果用預先畫好的貼圖。
- **PX-PERF-05(MUST)** 分頁到背景(`visibilitychange`)就暫停 ticker;暫停狀態單一來源、帶原因(`src/core/pause.ts`),音訊也訂閱同一個狀態。檢查:E2E `drawsDuring` = 0。
- **PX-PERF-06(SHOULD)** 同畫面素材約 20 張以上就合成圖集,減少請求與 batch。
- **PX-PERF-07(MUST)** 每個素材群組有 AVIF KB 預算(budgets「## 素材預算」),超過就建置失敗(`build-assets.mjs`、`check-assets.mjs`)。

### RES 解析度與版面
- **PX-RES-01(MUST)** 素材分 1x / 0.5x 兩級;單張上限 1x ≤ 2048²、0.5x ≤ 1024²(GPU / 記憶體限制,跨專案相同)。1x 檔案 = 顯示尺寸 × density(density 預設 2,背景類縮到上限內),0.5x = 1x 的一半無條件進位成偶數。級別看像素需求:`cover × min(DPR, 2) > 0.6 → 1x`(`src/assets/tier.ts`;專案可在「例外」另訂)。
- **PX-RES-02(MUST)** `resolution = min(devicePixelRatio, 2)`、`autoDensity: true`。
- **PX-RES-03(MUST)** 版面只有一個入口:renderer `resize` → SceneManager → `scene.layout(fit)`;元件不自己監聽 resize。

### A11Y 無障礙
- **PX-A11Y-01(MUST)** 可操作的 Pixi 物件設 `accessible = true`、`accessibleType = 'button'`、`accessibleTitle`(來自 i18n);Pixi 的 a11y 層把 title 寫進 div 的 `title`,E2E 用 `[title="…"]` 選。
- **PX-A11Y-02(MUST)** 只有 `src/components/a11y.ts` 可以碰 Pixi 內部 `_accessibleDiv`(加 aria 屬性、還原焦點);升級 Pixi 要回歸測試。
- **PX-A11Y-03(MUST)** `index.html` 有 `#sr-status`(`role=status`、`aria-live=polite`)與 `#sr-alert`(`role=alert`);畫面上的狀態變化(分數、錯誤)經 `announce.ts` 公告(先清空再寫)。
- **PX-A11Y-04(MUST)** 原生 `<dialog>` 開著時關掉場景輸入(`modal-guard.ts`;Pixi 的 pointermove 掛在 document 上);Esc 走 `cancel` 事件;關閉後焦點回到入口;確認框預設焦點在安全的按鈕。
- **PX-A11Y-05(SHOULD)** 焦點框只給鍵盤使用者(`input-modality.ts`,開機就追蹤)。
- **PX-A11Y-06(MUST)** 動畫、轉場、閃爍先問 `prefers-reduced-motion`(`services/motion.ts`),CSS 也要有 `@media (prefers-reduced-motion: reduce)`。

### I18N 文案
- **PX-I18N-01(MUST)** 玩家看得到的文字(Pixi Text / BitmapText、DOM 文字、`aria-label` 等、`accessibleTitle`)一律從 `src/i18n/en.ts` 取(typed key + `t()`),不寫死在 scene / component / controller。檢查:`check-i18n.mjs`(只看 sink,例外加 `// i18n-ignore: <理由>`)。

### INPUT 輸入
- **PX-INPUT-01(MUST)** 滑鼠、觸控、鍵盤 Tab + Enter 都能觸發按鈕;只擋 `button > 0`(右鍵 / 中鍵),不要寫 `button !== 0`(a11y 送來的事件沒有 button 欄位)。
- **PX-INPUT-02(MUST)** 觸控目標在最小縮放下 ≥ 44 CSS px(E2E `tap()` 會檢查)。
- **PX-INPUT-03(MUST)** `#app { touch-action: none }`;版面扣掉 `env(safe-area-inset-*)`(`safe-area.ts`;開發模式 `?inset=` 注入)。
- **PX-INPUT-04(MUST)** 橫式遊戲在直式畫面顯示 `#rotate` 並暫停(暫停原因 `rotate`);直式遊戲反之。

### NET 連線
- **PX-NET-01(MUST)** WebSocket:第一則 hello(launch token)、之後 resume(session token);指數退避上限 10 秒,收到 welcome 歸零;致命錯誤碼停止重連;斷線期間不送;重連後以伺服器的完整快照重建狀態。骨架:`--net ws`。
- **PX-NET-02(MUST)** iframe:父頁 origin 來自 `ancestorOrigins` / `referrer` 且在允許清單;收訊息檢查 `event.source === window.parent` 與精確 origin;送訊息用精確 origin,不用 `'*'`。骨架:`--iframe`。
- **PX-NET-03(MUST)** HTTP 請求有逾時(預設 10 秒,專案可另訂),不為了 API 呼叫加大型依賴。

### SEC 安全
- **PX-SEC-01(MUST)** token 不放 Web storage、不印到 console;伺服器來的文字一律 `textContent`,不用 `innerHTML`。

### TEST 驗證
- **PX-TEST-01(MUST)** 驗收情境的測試名稱以情境編號開頭(`SHOP-S1 …`);元件層級 = Vitest(`src/**/*.test.ts`,node 環境),E2E = Playwright。
- **PX-TEST-02(MUST)** E2E 用 a11y 層的選擇器(DOM id、role、`[title=]`);觸控 / 滑鼠座標從 Pixi 物件 bounds 計算,不寫死;測試模式 `?a11y=1` 一開始就啟用 a11y 層。
- **PX-TEST-03(MUST)** E2E 尺寸:1920×1080、1024×768@2x、844×390@3x,加專案額外尺寸(`E2E_EXTRA_SIZES`);直式 390×844@3x 檢查旋轉提示;任何 `pageerror` / `console.error` 就失敗。
- **PX-TEST-04(MUST)** 截圖寫暫存(`SHOTS_DIR`),不進 git;驗證完刪除。

## 新專案
```bash
bash <skill>/scripts/new-pixi.sh <目錄> --design 1920x1080 [--name <套件名>] [--title <標題>] [--net ws] [--iframe] [--no-install]
# 填 docs/performance-budgets.md 的 __佔位__(依簡報;推定值標「(推定)」;不設就填 —)
bash <skill>/scripts/new-pixi.sh --check <目錄>     # 骨架齊全、budgets 標題各一次、沒有未填佔位、pixi 8
```
- 骨架:`src/core/`(app、pause、scene-manager、layout、safe-area、orientation、announce、modal-guard、input-modality、audio)、`src/config/design.ts`、`src/scenes/{title,play}/`(範例,換成真正的場景)、`src/components/{a11y,Button}.ts`、`src/game/`(純邏輯 + 種子亂數)、`src/services/`、`src/i18n/`、`src/assets/`(群組 manifest、`early.ts`、`tier.ts`、loader)、`scripts/{build-assets,serve-dist}.mjs`、`scripts/schemas/`(從 `game-art-kit/schemas` 複製)、`tests/e2e/`、`tests/perf/`、`docs/performance-budgets.md`。
- 新增場景:`src/scenes/<name>/<Name>Scene.ts`(default export 工廠)+ `core/scene-manager.ts` 的 `SCENES` 加一行 + `src/assets/<group>/manifest.json`。
- 範例場景與 `tests/e2e/specs/demo.spec.ts`(DEMO-S*)換成真正的遊戲時一起改寫或刪除。

## 素材(與 game-concept-artist 的介面)
- 美術交 `art/assets/assets.json` + 1x 原圖(schema:`game-art-kit/schemas/assets.schema.json`)。缺的素材由本專案寫 `assets.needs.json`(`needs.schema.json`;尺寸是設計座標下的顯示尺寸),驗證:`node scripts/schemas/validate.mjs needs assets.needs.json`。
- `npm run assets -- --src <art/assets>`:驗證 → 每個群組產生 `src/assets/<group>/<id>@1x|@0.5x.avif` + `.png`(`opaque` 改 `.jpg`)、音訊複製、`manifest.json`(顯示尺寸、anchor、nineSlice、frames 格資訊)→ 檢查 KB 預算。產出進 git。
- frames 不另出 spritesheet JSON:格資訊(count、fps、frameWidth、frameHeight、columns,貼圖單位 = 1x px)寫在 manifest,`frameTextures()` 切格(hash 後的檔名無法被 spritesheet JSON 的 `meta.image` 參照)。
- 缺素材時用 `Graphics` 佔位,把 id 列進 `assets.needs.json`。

## 檢查腳本(既有專案也可用;專案已有同等檢查時用專案的)
```bash
node <skill>/scripts/check-layers.mjs <project> [--paths src/game,src/services,src/core]
node <skill>/scripts/check-i18n.mjs <project> [--src src]
node <skill>/scripts/check-assets.mjs <project> [--budgets docs/performance-budgets.md] [--art <art/assets>]
node <skill>/scripts/check-early.mjs <project> [--dist dist] [--boot boot,shared]   # 先 vite build
```
都印一行 JSON(`ok`、違規清單),違規結束碼 1、用法錯誤 2。

## 驗證順序(骨架專案)
1. `npm run typecheck`、`npx vitest run`(本地已安裝的工具;不要讓 npx 自動下載:`npm exec --no -- vitest run`)、`npm run build`。
2. 四個檢查腳本。
3. E2E:`serve.sh <name>-dev <project> 5173 -- npm run dev`,`PORT=<serve.sh 回的埠> npx playwright test`;要後端時照專案方式啟動,結束 teardown;`stop.sh`。
4. 效能:`vite build --outDir <暫存>`,`serve.sh <name>-dist <project> 4175 -- node scripts/serve-dist.mjs <暫存>`,
   `PORT=<埠> PERF_VIEW=desktop npx playwright test -c tests/perf/playwright.perf.config.ts first-screen scene-switch`,再 `PERF_VIEW=phone` 跑一次;soak 單獨跑(超過 540 秒用 Bash 背景執行)。每次 Bash 呼叫前估算 5 ×(可互動 + 等待)+ 啟動 ≤ 540 秒。
5. 資源釋放:`cycleLeak`(進出 4 次,第 3、4 次不可多於第 2 次;Pixi 8 的 GC 會延遲釋放 GPU 資源,快照前 fixture 會強制跑一次 `renderer.gc.run()`)、`drawsDuring` = 0。

## 已驗證的坑
- Pixi 8 的 `Container` 沒有 `worldVisible`;看可見性要往上走 `parent` 檢查 `visible`。
- 改了物件位置後立刻 `getBounds()` 可能拿到舊的 world transform:先等兩個影格(fixture `boundsOf`)。
- 非 batch 的 Graphics(較大的圖形)destroy 後 GL buffer 由 `GCSystem` 延遲釋放(預設 60 s),不是洩漏;量測前要強制 GC。
- Playwright 的 `isMobile + hasTouch` context 用 `page.touchscreen.tap()`,Pixi 收到 `pointerType: 'touch'`。
- 缺 favicon 會產生 404 console.error,骨架 `index.html` 放了 `<link rel="icon" href="data:,">`。

## 自我測試
```bash
bash <skill>/tests/run.sh          # 建骨架 → npm ci → tsc / vitest / build / 四個檢查 / E2E 全尺寸 / perf 一次 / 素材管線 / check-i18n 誤報漏報 / Worker 限速
```
需要網路(npm registry)與本機 Google Chrome;測完刪除暫存並停止服務。
