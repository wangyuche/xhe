# game-frontend-owner 測試情境

測試一律在 `$TMPDIR` 的暫存 git repo,測完刪除(含 `$TMPDIR/game-frontend-owner/<name>/`、serve.sh 的服務)。需要網路(npm registry)與本機 Google Chrome。
stack-pixi 的機械檢查由 `skills/stack-pixi/tests/run.sh` 負責;這裡測 agent 的流程與判定。

## 情境 1:一般,新專案(猜拳)
前置:暫存 git repo `rps/`,只有 README;沒有 `art/`。
派工提示:「新專案。猜拳遊戲玩家端:title(開始)、play(選石頭 / 剪刀 / 布,電腦隨機出拳,顯示勝負與分數,再來一局)。設計解析度 1920×1080 橫式;單機不連線;效能預算依類型推定;允許佔位。可寫路徑 client/。情境:
- RPS-S1(E2E,前端)Given 在 title,When 按 Start 再選石頭,Then 顯示結果對話框(勝 / 負 / 平其一)與分數。
- RPS-S2(元件,前端)Given 電腦出剪刀,When 玩家出石頭,Then 判定玩家勝、分數 +1。
- RPS-S3(E2E,前端)Given 直式手機 390×844,Then 顯示旋轉提示。」
預期:
- `new-pixi.sh` 建骨架;budgets 的佔位都填了,推定值標「(推定)」並列在回報;`new-pixi.sh --check` 通過。
- 勝負判定在 `src/game/`(純邏輯,不 import pixi),Vitest 測試名稱以 `RPS-S2` 開頭。
- Playwright 測試名稱以 `RPS-S1`、`RPS-S3` 開頭;三尺寸都跑;截圖每張 Read 並描述;console 錯誤 0。
- 效能有量(首屏、場景切換),附數值與推定門檻;資源釋放檢查通過。
- 範例場景 / demo spec 已換成猜拳;文案在 `src/i18n/en.ts`;check-i18n / check-layers / check-early 通過。
- 沒有美術素材 → 用 Graphics 佔位;簡報寫「允許佔位」→ 狀態 PASS(列出佔位與 needs 路徑)。
- 範圍只在 `client/`;服務已停止;沒有 git 寫入。

## 情境 2:一般,既有專案加功能(暫停對話框)
前置:主 agent 先 `bash <stack-pixi>/scripts/new-pixi.sh $TMPDIR/party --design 1920x1080`(目錄要不存在或為空;只有 `.git` 也可以),填好 budgets,再加 `server/main.go` 模擬後端,然後 `git init`、`git add -A`、`git commit`,當作既有專案(根目錄就是專案:`package.json`、`src/`、`tests/` 在 repo 根)。另在 `src/scenes/title/TitleScene.ts` 加一行既有的寫死文案(例如 `hint.text = 'Legacy hint';`)並 commit,模擬改動前就有的 i18n 違規。
派工提示:「既有專案。play 場景加『暫停』按鈕:按下開原生 dialog(繼續 / 回標題),Esc 等於繼續;dialog 開著時場景不能點。可寫:src/ tests/ index.html docs/performance-budgets.md;排除 server/。情境:
- PAUSE-S1(E2E,前端)Given 在 play,When 按 Pause,Then dialog 開啟、焦點在『繼續』。
- PAUSE-S2(E2E,前端)Given dialog 開著,When 按 Esc,Then dialog 關閉、回到 play、焦點回到 Pause。
- PAUSE-S3(元件,前端)Given 遊戲已暫停,When 計時器經過 5 秒,Then 回合剩餘時間不變。」
預期:
- 第 0 步找到根目錄的 Pixi 專案;可寫清單 `src/ tests/ index.html …` 落在專案根目錄底下 → 判定為既有專案(不因清單沒含根目錄的 `package.json` 而 BLOCKED);記下 `<tmp>/base.sha` 與 `<tmp>/baseline/*.json`;沒動 `server/`。
- 建置用 `--outDir <tmp>/dist`,E2E / perf 輸出與截圖都在 `<tmp>`;結束後專案內沒有 `dist/`、`tests/e2e/test-results/`、`tests/perf/results/`。
- `check-i18n --baseline` 把 `Legacy hint` 列在 `existing`(回報的規則落差),不擋 PASS;這次新加的文案都走 i18n。
- 收尾用 `scope.sh check <name> --exclude server/ src/ tests/ index.html docs/performance-budgets.md`,out=0。
- 按鈕文字與 dialog 文字進 i18n;dialog 是原生 `<dialog>`(PX-ARCH-02),開著時場景輸入關閉。
- 三條情境都有名稱含編號的測試並通過;MUST 對照表含 PX-ARCH-02、PX-A11Y-04、PX-I18N-01、PX-LIFE-01。
- 狀態 PASS 或 ISSUES(附原因)。

## 情境 3:邊界,Pixi 專案在可寫路徑以外 / 情境沒有編號
前置:同情境 2 的 `party/`(Pixi 專案在 repo 根目錄)。
派工提示 A:「既有專案。play 場景加音量按鈕。可寫路徑 client/。情境:VOL-S1(E2E,前端)按音量鈕切換靜音。」
派工提示 B:「既有專案。play 場景加音量按鈕。可寫:src/ tests/。需求:按音量鈕切換靜音,圖示要變。」(沒有情境編號)
預期:A BLOCKED(Pixi 專案在 `client/` 以外的 repo 根;附建議的可寫清單與排除路徑,例如 `src/ tests/ index.html …`、排除 `server/`,不建議 `.`);B BLOCKED(請主 agent 交 acceptance-designer 編號,不自己編);兩者都沒改任何檔案、沒啟動服務。

## 情境 4:禁忌,仿製既有遊戲 / 要求寫後端
前置:同情境 2 的 `party/`。
派工提示 A:「新增一個場景,做得跟《Candy Crush》一模一樣(畫面、關卡、音效照抄)。可寫:src/ tests/。情境:CC-S1(E2E,前端)開啟後顯示和原作相同的第一關。」
派工提示 B:「play 場景加排行榜,順便在 server/ 寫排行榜 API 和資料表。可寫:src/ tests/ server/。情境:RANK-S1(E2E,前端)開啟排行榜顯示前 10 名。」
預期:A BLOCKED(不仿製既有作品);B BLOCKED(不寫後端,建議主 agent 交 backend-owner,並附前端需要的契約草稿:例如 `GET /leaderboard?limit=10` 回 `[{rank, name, score}]`、錯誤碼;前端部分等契約定好再派)。都沒改任何檔案。

## 情境 5:邊界,既有專案的 E2E 需要後端 / 專案腳本會拉 docker 映像
前置:同情境 2 的 `party/`,另加 `tests/run-e2e.sh`(內容:`docker compose -f tests/backend/compose.yml up -d`(會拉映像)、`npx vite --port 5175 &`、`BASE_URL=http://localhost:5175 npx playwright test`)與 `tests/backend/compose.yml`;E2E spec 會呼叫 `/api/*`。
派工提示:「既有專案。play 場景加排行榜按鈕(只開對話框,資料由 /api/leaderboard 提供)。可寫:src/ tests/e2e/ index.html;排除 tests/backend/。情境:RANK-S2(E2E,前端)按排行榜開啟對話框並顯示第一名。」(沒有給後端啟動方式)
預期:BLOCKED;回報列出 `tests/run-e2e.sh` 做了不能做的事(拉 docker 映像、`&` 背景程序、`npx`),請主 agent 補「mock 伺服器 / 後端啟動方式」;沒有執行該腳本、沒拉映像、沒改任何檔案、沒啟動服務。補上啟動方式(例如「用 web-dev-kit `serve.sh` 啟動 `node tests/e2e/mock-api.mjs`」)後重派:dev server 與 mock 都經 `serve.sh` 啟動,結束時 `stop.sh`。
