---
name: stack-pixi
description: PixiJS 8 + Vite 8 + TypeScript 遊戲 / 大廳玩家端的規則(PX-XXX-NN,MUST / SHOULD)與骨架:場景各自 chunk 與 early-boot 白名單、a11y DOM 層(Pixi AccessibilitySystem + 原生 dialog + live region)、i18n、1x / 0.5x AVIF + PNG 素材建置與 KB 預算、效能預算量測(gzip 靜態伺服器 + Slow 4G + 4× CPU)、Playwright 三尺寸 E2E、資源釋放檢查、WebSocket / iframe。game-frontend-owner 寫 Pixi 前端時使用;碰到 import pixi.js 的檔案也適用。MahjongParty 文件引用的 `/pixi-style` 就是這個 skill(編號與意義相同)。
paths: ["**/src/scenes/**/*.ts", "**/src/core/**/*.ts", "**/src/components/**/*.ts", "**/src/assets/**/*.ts", "**/vite.config.ts", "**/tests/e2e/**/*.ts", "**/tests/perf/**/*.ts"]
---

# stack-pixi

`<skill>` = 這個 skill 的目錄;`<kit>` = web-dev-kit skill 目錄;`<project>` = Pixi 專案目錄(有 `package.json` 且依賴 `pixi.js` 8)。

## 規則優先序
1. 專案自己的規則文件(例如 `docs/architecture/code-review-rules/`、budgets 文件、`CLAUDE.md`)比這裡嚴格或專案特有的,照專案;專案的例外條款(EX-n)照它寫的條件。
2. 這裡的 PX 規則:**MUST** 不可違反(違反就是 code review Blocker,退回時引用編號);**SHOULD** 不做要寫理由。
3. 每個專案不同的數值(效能門檻、素材 KB 預算、設計解析度)不寫在規則裡,放專案的 `docs/performance-budgets.md`。
- 編號只能新增、不能改號或改意義。MahjongParty lobby 已引用(`git grep -ho 'PX-[A-Z0-9]*-[0-9]*'`,加上 `PX-FMT-01 / 02` 這種斜線寫法):ARCH-01/02、FMT-01/02/06/07、LIFE-01–03、LOAD-01/03/05/06、PERF-03–06、RES-01–03;意義照 `agent-specs/game-frontend-owner.md` 的對照表。
- **保留不用**的號碼(lobby 引用過或可能用過、但意義不明,不得另定意義):FMT-02–05、LOAD-02、LOAD-04、PERF-01、PERF-02。新規則從各類別「lobby 引用過的最大號 + 1」開始。
- 改號紀錄(2026-11-22,PR #28 的初版誤用了保留號):LOAD-02 → **LOAD-07**、LOAD-04 → **LOAD-08**、PERF-01 → **PERF-08**、PERF-02 → **PERF-09**;舊版 LOAD-01 的「只從 SceneManager 動態 import」拆成 **LOAD-09**、LOAD-06 的「BGM 不在第一次手勢前下載」拆成 **LOAD-10**、RES-01 的 density 公式拆成 **RES-04**、級別公式拆成 **RES-05**、FMT-01 的 JPG 備援拆成 **FMT-08**。

## 版本
骨架鎖定:pixi.js 8.23.0、vite 8.3.8、typescript 7.0.2、vitest 5.1.1、@playwright/test 1.65.1(`channel: 'chrome'`,用系統 Chrome)、sharp 0.35.5、Node 版本見下方「Node 版本規則」。`template/package-lock.json` 鎖住全部依賴,`new-pixi.sh` 用 `npm ci`。

### Node 版本規則
- 專案有指定(`.nvmrc` / `.node-version`、`package.json` 的 `engines.node` / `volta.node`、Dockerfile 的 `FROM node:<N>`)→ 本機主版本 **≥ 指定的主版本**(多處指定取最大值;`engines` 是範圍時取下限的主版本)。
- 都沒指定 → 本機主版本 ≥ 22。
- 本機比指定的新可以,回報註明差異(例如「本機 node 24,專案 Dockerfile node:22」);比指定的舊 → 停止(BLOCKED,升級由使用者執行)。

## PX 規則

### ARCH 分層
- **PX-ARCH-01(MUST)** 純邏輯層(`src/game/**`、`src/services/**`,專案可擴充)不 import `pixi.js` / `@pixi/*`。檢查:`check-layers.mjs`;骨架另有 `src/game/no-pixi.test.ts`。
- **PX-ARCH-02(MUST)** 對話框、面板、表單用 DOM(原生 `<dialog>` + `showModal()`),焦點與 Esc 交給瀏覽器;不在 Pixi 裡自己畫對話框。

### FMT 格式
- **PX-FMT-01(MUST)** 圖片 AVIF 為主、PNG 備援,執行時偵測 AVIF 支援(骨架:Pixi `Assets` 的 src 陣列依支援度選)。
- **PX-FMT-06(SHOULD)** 頻繁變動的數字(分數、計時、滾動)用 `BitmapText`,不用每幀重建貼圖的 `Text`。
- **PX-FMT-07(MUST)** 音訊 ogg(Opus)+ m4a(AAC):`canPlayType('audio/ogg; codecs=opus')` 支援用 ogg,否則 m4a(Safari)。
- **PX-FMT-08(SHOULD)** 不透明的大背景可用 JPG 代替 PNG 當備援(骨架:素材 `opaque: true` 時 `build-assets.mjs` 出 JPG)。

### LIFE 生命週期
- **PX-LIFE-01(MUST)** 場景 / 物件離開時 `destroy({ children: true })`,並移除自己加的監聽、ticker 回呼、dialog 綁定;貼圖由 `Assets` 管理,不在物件內 destroy。檢查:E2E `cycleLeak`。
- **PX-LIFE-02(MUST)** 全站只有一個 `Application`;stage 下同時只掛一個場景(由 SceneManager 切換)。
- **PX-LIFE-03(MUST)** `webglcontextlost` 要 `preventDefault()` 並顯示錯誤畫面與「重新載入」,不能變白畫面。

### LOAD 載入
- **PX-LOAD-01(MUST)** 程式與素材按場景 / 面板分 chunk 與群組(bundle);首屏只載 boot 批次。骨架的 boot 批次 = `src/assets/early.ts` 的 `BOOT_GROUPS`,檢查 `check-early.mjs`;既有專案用專案自己的首屏檢查(例如 lobby `src/assets/early-groups.test.ts`)。面板可以由各自的入口動態 `import()`(lobby 的信箱、活動、好友、每日獎勵就是這樣)。
- **PX-LOAD-03(MUST)** 素材檔名帶內容 hash(Vite 預設);檔名中的 `@1x` / `@0.5x` 保留給 Pixi 判斷解析度,不另作他用。
- **PX-LOAD-05(SHOULD)** 圖片在 Worker 解碼(Pixi 預設 `preferWorkers`);改到主執行緒要在 budgets「例外」寫理由與量測。
- **PX-LOAD-06(MUST)** boot 批次要有傳輸量預算(`boot_kb`,數值在專案 budgets);要有啟動量測點(骨架:`#loading` 隱藏 = 可互動)。
- **PX-LOAD-07(MUST)** Vite `assetsInlineLimit: 0`(不內嵌 data URL,Pixi 才能依副檔名與 `@Nx` 判斷);pixi 全部放同一個 chunk(避免它內部的動態 import 在 Slow 4G 下多一輪請求)。
- **PX-LOAD-08(MUST)** `Assets.load` 前查 `Assets.cache.has(alias)`;unload 只 unload 自己載過、cache 裡真的有的 alias;共用貼圖參考計數,歸零才 unload(骨架 `acquireGroup` / `releaseGroup`)。
- **PX-LOAD-09(SHOULD)** 場景(不含面板)只從 SceneManager 動態 `import()`,其他地方不直接 import 場景模組。
- **PX-LOAD-10(SHOULD)** BGM 在第一次使用者手勢後才下載,不計入首屏傳輸量(骨架 `core/audio.ts`)。

### PERF 效能
- **PX-PERF-03(SHOULD)** 大量重複出現的物件(粒子、飛行物、牌)用物件池,不每次 new / destroy。
- **PX-PERF-04(MUST)** 常駐畫面不用 filter(DropShadow、Blur 等,每個 filter 多一次 render pass);效果用預先畫好的貼圖。
- **PX-PERF-05(MUST)** 分頁到背景(`visibilitychange`)就暫停 ticker;暫停狀態單一來源、帶原因(`src/core/pause.ts`),音訊也訂閱同一個狀態。檢查:E2E `drawsDuring` = 0。
- **PX-PERF-06(SHOULD)** 同畫面素材約 20 張以上就合成圖集,減少請求與 batch。
- **PX-PERF-07(MUST)** 每個素材群組有 AVIF KB 預算(budgets「## 素材預算」),超過就建置失敗(`build-assets.mjs`、`check-assets.mjs`)。
- **PX-PERF-08(MUST)** 效能量測用 production build + gzip 靜態伺服器(`scripts/serve-dist.mjs`;`vite preview` 不壓縮),Slow 4G(latency 562.5 ms、下行 1.44 Mbps、上行 675 kbps)+ 4× CPU、冷快取、每次新 context、5 次取中位數;1920×1080 與 844×390@3x。
- **PX-PERF-09(MUST)** 門檻讀專案的 budgets 文件(骨架 `docs/performance-budgets.md`);「不得退步」的基準是同一份文件的「最新實測」。

### RES 解析度與版面
- **PX-RES-01(MUST)** 素材分 1x / 0.5x 兩級;單張上限 1x ≤ 2048²、0.5x ≤ 1024²(GPU / 記憶體限制,跨專案相同,非專案值)。
- **PX-RES-02(MUST)** `resolution = min(devicePixelRatio, 2)`、`autoDensity: true`。
- **PX-RES-03(MUST)** 版面只有一個入口:renderer `resize` → SceneManager → `scene.layout(fit)`;元件不自己監聽 resize。
- **PX-RES-04(MUST)** 1x 檔案 = 顯示尺寸 × density(density 預設 2;單張與整張 frames sheet 超過 2048 時自動降低,以 game-art-kit `sprite.mjs density` 的輸出為準);0.5x = 1x 的一半,無條件進位成偶數。
- **PX-RES-05(SHOULD)** 1x / 0.5x 依實際像素需求選,不看裝置類型。新專案預設 `cover × min(DPR, 2) > 0.6 → 1x`(cover = 設計座標到畫面的縮放;`src/assets/tier.ts`,同 lobby 的例外 EX-01);專案自己的規則或例外條款優先。

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
- **PX-TEST-04(MUST)** 截圖、建置輸出、E2E / perf 輸出寫暫存(`SHOTS_DIR`、`vite build --outDir`、`E2E_OUTPUT_DIR`、`PERF_OUTPUT_DIR`、`PERF_RESULTS_DIR`),不進 git、不放專案內;截圖回報後由主 agent 刪除(agent 自己不刪,主 agent 要看)。既有專案的測試設定寫死專案內的輸出路徑時,見「既有專案」。

## 新專案
```bash
bash <skill>/scripts/new-pixi.sh <目錄> --design 1920x1080 [--name <套件名>] [--title <標題>] [--net ws] [--iframe] [--no-install]   # --help 看用法;目錄只有 .git 也可以
# 填 docs/performance-budgets.md 的 __佔位__(依簡報;推定值標「(推定)」;不設就填 —)
bash <skill>/scripts/new-pixi.sh --check <目錄>     # 骨架齊全、budgets 標題各一次、沒有未填佔位、pixi 8
```
- 骨架:`src/core/`(app、pause、scene-manager、layout、safe-area、orientation、announce、modal-guard、input-modality、audio)、`src/config/design.ts`、`src/scenes/{title,play}/`(範例,換成真正的場景)、`src/components/{a11y,Button}.ts`、`src/game/`(純邏輯 + 種子亂數)、`src/services/`(`--net ws` 加 `src/services/net/`、`--iframe` 加 `src/services/iframe/`)、`src/i18n/`、`src/assets/`(群組 manifest、`early.ts`、`tier.ts`、loader)、`scripts/{build-assets,serve-dist}.mjs`、`scripts/schemas/`(從 `game-art-kit/schemas` 複製)、`tests/e2e/`、`tests/perf/`、`docs/performance-budgets.md`。
- 新增場景:`src/scenes/<name>/<Name>Scene.ts`(default export 工廠)+ `core/scene-manager.ts` 的 `SCENES` 加一行 + `src/assets/<group>/manifest.json`。
- 範例場景與 `tests/e2e/specs/demo.spec.ts`(DEMO-S*)換成真正的遊戲時一起改寫或刪除。

## 素材(與 game-concept-artist 的介面)
- 美術交 `art/assets/assets.json` + 1x 原圖(schema:`game-art-kit/schemas/assets.schema.json`)。缺的素材由本專案寫 `assets.needs.json`(`needs.schema.json`;尺寸是設計座標下的顯示尺寸),驗證:`node scripts/schemas/validate.mjs needs assets.needs.json`。
- `npm run assets -- --src <art/assets>`:驗證 → 每個群組產生 `src/assets/<group>/<id>@1x|@0.5x.avif` + `.png`(`opaque` 改 `.jpg`)、音訊複製、`manifest.json`(顯示尺寸、anchor、nineSlice、frames 格資訊)→ 檢查 KB 預算。產出進 git。
- frames 不另出 spritesheet JSON:格資訊(count、fps、frameWidth、frameHeight、columns,貼圖單位 = 1x px)寫在 manifest,`frameTextures()` 切格(hash 後的檔名無法被 spritesheet JSON 的 `meta.image` 參照)。
- 顯示時一律用 manifest 的 `width` / `height`(顯示尺寸)`setSize()`,不要用貼圖本身的尺寸(0.5x 進位成偶數後,貼圖邏輯尺寸可能和 1x 差 1–3 px)。
- 級別在每次切換場景、載入群組前依「轉到正確方向後」的畫面重算;Pixi 內部 alias 是 `<id>#<級別>`,`texture(group, id)` 取該群組載入的那一份;`frameTextures()` 的格貼圖由群組 unload 時統一 destroy,呼叫端不要自己 destroy。
- BGM:`playSfx(src, { loop: true })` 回傳停止函式,場景 `destroy()` 要呼叫(PX-LIFE-01)。
- 缺素材時用 `Graphics` 佔位,把 id 列進 `assets.needs.json`。

## 檢查腳本(既有專案也可用;專案已有同等檢查時用專案的)
```bash
node <skill>/scripts/check-layers.mjs <project> [--paths src/game,src/services] [--baseline <json>]   # --paths 只列專案實際強制不 import pixi 的資料夾
node <skill>/scripts/check-i18n.mjs <project> [--src src] [--baseline <json>]
node <skill>/scripts/check-assets.mjs <project> [--budgets docs/performance-budgets.md] [--art <art/assets>] [--baseline <json>]
node <skill>/scripts/check-early.mjs <project> --dist <暫存>/dist [--boot boot,shared] [--baseline <json>]   # 先 vite build --outDir <暫存>/dist
```
- 都印一行 JSON。結束碼:**0** 通過、**1** 有新增違規、**2** 用法錯誤(含選項缺值、`--dist` 目錄不存在 = 還沒建置)、**3** `"layout":"absent"`(只有 check-assets / check-early:專案沒有 stack-pixi 的結構——沒有任何 `src/assets/<group>/manifest.json`、vite 沒開 `build.manifest`、沒有 `src/assets/early.ts` 也沒給 `--boot`)。3 不是違規:改用專案自己的同等檢查,沒有就列為規則落差。
- `--paths`:`src/core` 會 import pixi,不要列。既有專案用專案**實際強制**的路徑(例如專案自己的 `no-pixi.test.ts` 涵蓋的資料夾),不照文件推測。
- **`--baseline <json>`**:給同一支腳本在改動前的輸出。每筆違規有 `key`(check-layers / check-i18n:`檔案|正規化後的該行文字`,不含行號;check-early:素材路徑去掉 hash;check-assets:錯誤訊息的數字換成 `#`)。基準已有的移到 `existing`、不算失敗;只有新增的 key(或同一個 key 次數變多)才結束碼 1。既有專案的既有違規不擋 PASS,靠這個區分。
- `bg-job.mjs`:讓不是伺服器的長時間指令(soak)也經 web-dev-kit `serve.sh` 背景執行:
  `bash <kit>/scripts/serve.sh <name>-soak <project> 4190 -- node <skill>/scripts/bg-job.mjs -- env PERF_BASE_URL=http://127.0.0.1:<dist 埠> … node_modules/.bin/playwright test -c tests/perf/playwright.perf.config.ts soak`;
  `curl -s http://127.0.0.1:<port>/` 回 `{"state":"running"|"done","code":…}`,結束後 `bash <kit>/scripts/stop.sh <name>-soak`。子指令的環境變數不含 `PORT`。

## 既有專案
- 不改專案結構;骨架的檔案位置(`src/assets/early.ts`、`<group>/manifest.json`、`tests/perf/*.perf.spec.ts`)不存在時,用專案自己的同等檢查或測試(回報寫名稱,例如 lobby `src/assets/early-groups.test.ts`、`src/assets/*-assets.test.ts`),沒有就列為規則落差,不判失敗。
- E2E fixture(`cycleLeak`、`drawsDuring`、`tap()` 等)是骨架提供的;既有專案用專案自己的同等工具(例如 lobby fixture 的 `drawsDuring`、TC-22-59 的貼圖計數),沒有就列為規則落差。
- 建置一律 `--outDir <暫存>/dist`(`npm run build -- --outDir <暫存>/dist --emptyOutDir`,build script 最後一個指令要是 `vite build`;不是的話分開跑 typecheck 與 `vite build --outDir`)。專案的 Playwright 設定寫死專案內輸出路徑(例如 lobby `tests/e2e/screenshots`、`tests/e2e/test-results`、`tests/perf/results`)而且有被 gitignore 時可以使用,結束時刪掉這次新出現的,回報列出。
- 專案規則文件與專案自己的程式明顯不一致(例如文件說 `src/core/**` 不可 import pixi,但 `src/core/app.ts` 就 import 了)→ 回報「專案文件與程式不一致」,檢查用專案實際強制的範圍,不自動停止。

## 驗證順序(骨架專案)
1. `npm run typecheck`、`npm exec --no -- vitest run`(只用本地已安裝的工具,不讓 npx 自動下載)、`npm run build -- --outDir <暫存>/dist --emptyOutDir`。
2. 四個檢查腳本。
3. E2E:`bash <kit>/scripts/serve.sh <name>-dev <project> 5173 -- npm run dev`,`PORT=<serve.sh 回的埠> SHOTS_DIR=<暫存>/shots E2E_OUTPUT_DIR=<暫存>/e2e npm exec --no -- playwright test`;要後端時照簡報給的方式啟動,結束 teardown;`bash <kit>/scripts/stop.sh <name>-dev`。
4. 效能:`vite build --outDir <暫存>/dist`,`bash <kit>/scripts/serve.sh <name>-dist <project> 4175 -- node scripts/serve-dist.mjs <暫存>/dist`,
   `PORT=<埠> PERF_VIEW=desktop PERF_RESULTS_DIR=<暫存>/perf PERF_OUTPUT_DIR=<暫存>/perf-out npm exec --no -- playwright test -c tests/perf/playwright.perf.config.ts first-screen scene-switch`,再 `PERF_VIEW=phone` 跑一次;soak 單獨跑(預估超過 540 秒就經 `serve.sh` + `bg-job.mjs` 背景執行)。每次 Bash 呼叫前估算 5 ×(可互動 + 等待)+ 啟動 ≤ 540 秒。
5. 資源釋放:`cycleLeak`(進出 4 次,第 3、4 次不可多於第 2 次;Pixi 8 的 GC 會延遲釋放 GPU 資源,快照前 fixture 會強制跑一次 `renderer.gc.run()`)、`drawsDuring` = 0。

## 已驗證的坑
- Pixi 8 的 `Container` 沒有 `worldVisible`;看可見性要往上走 `parent` 檢查 `visible`。
- 改了物件位置後立刻 `getBounds()` 可能拿到舊的 world transform:先等兩個影格(fixture `boundsOf`)。
- 非 batch 的 Graphics(較大的圖形)destroy 後 GL buffer 由 `GCSystem` 延遲釋放(預設 60 s),不是洩漏;量測前要強制 GC。
- Playwright 的 `isMobile + hasTouch` context 用 `page.touchscreen.tap()`,Pixi 收到 `pointerType: 'touch'`。
- 缺 favicon 會產生 404 console.error,骨架 `index.html` 放了 `<link rel="icon" href="data:,">`。

## 自我測試
```bash
bash <skill>/tests/run.sh          # 建骨架 → npm ci → tsc / vitest / build(暫存)/ 四個檢查(違規、--baseline、layout absent、用法錯誤)/ E2E 全尺寸 / perf 一次(soak 經 bg-job)/ 素材管線 / check-i18n 誤報漏報 / Worker 限速
```
需要網路(npm registry)與本機 Google Chrome;測完刪除暫存並停止服務。
