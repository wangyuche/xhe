# xhe

我的 Claude Code skill 倉庫。每個 skill 放在 `skills/<名稱>/SKILL.md`。

| skill | 用途 |
|---|---|
| `agent-forge` | 造專業 agent、協調多個 agent 同時做事、依使用成果改進 agent |
| `tw-stock-calc` | 台股技術指標與合理價的固定計算腳本(tw-stock-analyst 使用) |
| `tw-bottom-signal` | 台股大盤 / 個股「底部訊號」:30 / 60 分 K 依序判斷鈍化、背離、黃金交叉、突破,輸出標記點位的 SVG(需 `fugle.sh`) |
| `tw-three-blades` | 台股大盤 / 個股「均線三刀流」(刀神):60 分 K 的 20 / 60 / 240MA,小橘斜率判方向、藍綠交叉＋KD 判進場、排列與雙斜率,輸出結論與 SVG(需 `fugle.sh`) |
| `audio-transcribe` | 錄音 / 影片轉中文逐字稿:ffmpeg 轉 wav → whisper.cpp 轉錄(防重複參數)→ 清幻覺與重複 |
| `mac-widget-kit` | Mac 桌面浮窗 / 選單列 widget 骨架與腳本,免 Xcode(mac-widget-builder 使用) |
| `web-dev-kit` | 網站驗證腳本:啟停 dev server、Chrome 整頁截圖、轉發比對、範圍檢查、秘密掃描、本機 PostgreSQL |
| `stack-react` | React 元件與 Vitest 測試規則 |
| `stack-nextjs` | Next.js 16 前端規則與骨架(轉發、契約型別、Prism mock、Playwright) |
| `stack-go` | Go 後端規則與骨架(路由表、OpenAPI 3.0.3 契約測試、goose migration) |
| `stack-pixi` | PixiJS 8 + Vite 8 + TypeScript 遊戲 / 大廳玩家端規則(PX-XXX-NN,MUST / SHOULD)與骨架:場景 chunk 與首屏白名單、a11y 層、i18n、1x / 0.5x AVIF 素材與 KB 預算、效能預算量測、三尺寸 E2E、資源釋放、WebSocket / iframe(game-frontend-owner 使用;MahjongParty 文件的 `/pixi-style` 就是它) |
| `github-bot` | 以機器人身分(GitHub App 或機器人帳號)commit、push 功能分支、開 PR,自己 code review 沒問題就以 review 過的 SHA 合併(只限沒有 CI 的 repo;不直接推 main) |
| `gitlab-bot` | 在自建 GitLab(或 gitlab.com)commit、push 功能分支、開 MR,review 沒問題以 review 過的 SHA 合併(只限沒有 CI 的專案;不直接推 main);多專案共用一筆鑰匙圈 token(需 `api` + `write_repository`) |
| `short-video-kit` | 9:16 短影音腳本:轉文字、停頓偵測、say 旁白、卡片 / 字幕渲染、錄網頁、ffmpeg 合成(含 AI 圖運鏡、音效)、ComfyUI 影格組影片、規格驗證(short-video-maker 使用) |
| `game-art-kit` | 區網 ComfyUI 出圖腳本:check、上傳參考圖、送 workflow 輪詢下載(不在伺服器留檔)、workflow 骨架(出圖、LTX-2.3 / Wan 2.2 圖生影片、配樂、音效)、角色動作圖(Codex)、角色語音(ElevenLabs)、拼分鏡表(game-concept-artist、short-video-maker 使用);位址放 `~/.config/game-art-kit/config` |
| `spec-site-kit` | 產品規格網頁腳本:schema、依狀態檢查來源(檔案與行號存在、已完成每端有程式與測試、未開始的關鍵字在程式裡 git grep 不到)、合併各模組、產生單一自足 HTML(無 JavaScript、無品牌樣式)、可重現抽查(product-spec-writer 使用) |
| `gcp-ops-kit` | GCP / GKE 審查與受控變更腳本:唯讀白名單盤點(寫檔前遮蔽秘密)、固定嚴重度規則(CIS GCP Foundations v3.0.0)、k8s YAML / kustomize 審查、變更計畫(允許清單、可否還原、還原指令、放寬安全標示、sha256)、只執行逐條核准的變更、單一 HTML 報告、PreToolUse 守門 hook(gcp-guardian 使用) |
| `db-review-kit` | PostgreSQL / goose migration 審查腳本(只連自己建立的暫存容器):暫存容器(tmpfs、唯讀 bootstrap、隨機秘密、DSN 守門、拒絕非本機 docker)、goose roundtrip、鎖觀察、GRANT 矩陣、併發 / deadlock、種子與 EXPLAIN、分區檢查、隔離跑整合測試(db-reviewer 使用) |

## Agents

每個 agent 放在 `agents/<名稱>.md`,規格放在 `agent-specs/<名稱>.md`。

| agent | 用途 |
|---|---|
| `tw-stock-analyst` | 台股個股分析:基本面、合理價、時事、技術面、1–2 週價位預測(只讀、不寫檔) |
| `mac-widget-builder` | Mac 桌面 / 選單列 widget:SwiftUI + AppKit,只用 Command Line Tools 編譯,實際取資料與預覽驗證 |
| `acceptance-designer` | 網站 feature 的驗收情境設計(只讀):編號情境、測試層級、待決產品問題 |
| `frontend-owner` | 網站前端(React / Next.js):依驗收情境實作與測試、截圖驗證;有「僅設計規範」模式,為每個專案寫專屬 DESIGN.md |
| `backend-owner` | 網站後端(Go):實作、維護 OpenAPI 契約、httptest 與 curl 驗證;有「僅契約」模式 |
| `integration-verifier` | 網站整合驗證(只讀):真實前後端一起跑,轉發、截圖、E2E、情境對照 |
| `short-video-maker` | 短影音:GitHub repo、影片或主題 / 文案 → 1080×1920、≤60 秒 MP4(圖卡 / 錄網頁 / 挑精華 / 去停頓 / ComfyUI 生成插圖、動態鏡頭、配樂、音效),旁白與字幕,實際驗證規格與響度 |
| `game-frontend-owner` | PixiJS 遊戲 / 大廳玩家端(正式版):新專案用 stack-pixi 骨架、既有專案照專案規則;Vitest + Playwright 三尺寸、效能預算、資源釋放、MUST 對照;缺素材寫 assets.needs.json 交給 game-concept-artist |
| `game-concept-artist` | 遊戲示意圖與分鏡:ComfyUI 出圖,照各遊戲 `art/STYLE.md`,角色多張一致(參考圖編輯模型),逐張看圖;風格試作 / 定稿 / 角色定裝 / 一般 / 遊戲素材 / 角色動作(Codex)/ 角色語音(ElevenLabs) |
| `product-spec-writer` | 產品規格整理(企劃角色,只整理現況):讀規格、進度與程式,產出 `docs/spec-site/`(spec.json + index.html),每個功能標狀態並附檔案行號;待決事項、文件與程式不一致;不改規格與程式、不寫新企劃 |
| `gcp-guardian` | GCP 專案 / GKE 管家:用專用 SA 審查 IAM、網路、GCS、Cloud SQL、Compute、GKE 與 workload,審 k8s YAML,網頁報告;管理 GKE / 修正問題先出計畫,只執行使用者逐條核准的條目(dry-run、before/after、還原指令) |
| `db-reviewer` | PostgreSQL / migration 審查(只讀):9 個面向、暫存容器實測(up/down/up、鎖、GRANT、併發、EXPLAIN、整合測試)、編號意見與總結;專案值來自 `.claude/db-review.md`,缺時產出設定草稿 |

安裝(全域連結,在倉庫根目錄執行):

```bash
mkdir -p ~/.claude/agents
ln -s "$(pwd)/agents/tw-stock-analyst.md" ~/.claude/agents/tw-stock-analyst.md
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/tw-stock-calc" ~/.claude/skills/tw-stock-calc   # agent 依賴的計算腳本
ln -s "$(pwd)/agents/mac-widget-builder.md" ~/.claude/agents/mac-widget-builder.md
ln -s "$(pwd)/skills/mac-widget-kit" ~/.claude/skills/mac-widget-kit  # widget 骨架與腳本
```

`tw-stock-analyst` 需要在 host 核准規格中列出的網域;可選擇設定環境變數 `FINMIND_TOKEN` 提高 FinMind 額度(免 token 額度用完時 FinMind 回 402,報告會標「無資料(FinMind 額度用完)」)。

### 台股(tw-bottom-signal、audio-transcribe、fugle.sh)


```bash
ln -s "$(pwd)/skills/tw-bottom-signal" ~/.claude/skills/tw-bottom-signal   # 底部訊號(需要下面的 fugle.sh)
ln -s "$(pwd)/skills/audio-transcribe" ~/.claude/skills/audio-transcribe   # 法說會錄音轉文字
brew install ffmpeg whisper-cpp
mkdir -p ~/.cache/whisper && curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
# 模型放在別處時(本機設定,不進 git):
# mkdir -p ~/.config/audio-transcribe && echo 'WHISPER_MODEL=<模型路徑>' > ~/.config/audio-transcribe/config
```

**`~/.claude/tg/fugle.sh`(本機檔案,不在 repo):** [富果 MarketData API](https://developer.fugle.tw/) 的包裝腳本,金鑰只由它讀取。用法 `fugle.sh <endpoint> [輸出檔]`:呼叫 `https://api.fugle.tw/marketdata/v1.0/stock/<endpoint>`;沒給輸出檔時把回應印到 stdout,有給時寫進檔案並印 `{"http":<狀態碼>}`。參考寫法(金鑰放 `~/.claude/tg/fugle_key`,`chmod 600`;富果金鑰是英數字,這個寫法不處理 `"`、`\` 跳脫):

```bash
#!/bin/bash
KEYF="$HOME/.claude/tg/fugle_key"
[ -s "$KEYF" ] || { echo '{"error":"no fugle_key file"}'; exit 1; }
URL="https://api.fugle.tw/marketdata/v1.0/stock/$1"
# 金鑰經 stdin 的 curl 設定傳入,不出現在指令列(ps 看不到)
HDR=$(printf 'header = "X-API-KEY: %s"' "$(tr -d ' \r\n' < "$KEYF")")
if [ -n "$2" ]; then printf '%s\n' "$HDR" | curl -s -m 20 -K - -o "$2" -w '{"http":%{http_code}}\n' "$URL"
else printf '%s\n' "$HDR" | curl -s -m 20 -K - "$URL"; rc=$?; echo; exit $rc; fi
```

沒有 `fugle.sh` 時:`tw-stock-analyst` 盤中即時價改用 Yahoo Finance(報告會註明),其他分析不受影響;`tw-bottom-signal` 沒有替代來源,會報錯結束(結束碼 1)。

網站 agent 組(安裝與流程):

```bash
for a in acceptance-designer frontend-owner backend-owner integration-verifier; do ln -s "$(pwd)/agents/$a.md" ~/.claude/agents/$a.md; done
for k in web-dev-kit stack-react stack-nextjs stack-go; do ln -s "$(pwd)/skills/$k" ~/.claude/skills/$k; done
```

需要 Node.js ≥ 24.18、Go ≥ 1.26(`brew install node go`)、Google Chrome;PostgreSQL 選用 Docker。流程:(新前端先由主 agent 問使用者風格,派 frontend-owner「模式:僅設計規範」寫 `design/DESIGN.md` 並 commit;不需要時派工寫「不需要設計規範」)→ acceptance-designer 起草情境 → 使用者回答待決問題 → (平行時先 backend-owner「模式:僅契約」)→ frontend-owner / backend-owner 各在獨立 worktree 實作 → 主 agent commit 到 `agent/<agent>/<task>` 分支 → 單位 verifier → 合併到整合分支 → integration-verifier PASS → 主 agent 開 MR / PR 並以驗證過的 SHA 合併(GitLab:`glab mr merge <MR> --sha <SHA>`,SHA 不符會被拒絕;沒有遠端時本地合併);刪分支、force-push、部署仍先問使用者。GitLab:建一個專用機器人使用者(例如 `claude-bot`,Regular、非 admin),以 Developer 加入網站專案或 group,用它的 Personal Access Token(scopes 只有 `api` + `write_repository`)執行 `glab auth login`;一個 glab 登入即可跨專案。各專案 `main` 設為 No one 可 push、Developers + Maintainers 可 merge。自我測試:`bash skills/web-dev-kit/tests/run.sh`、`bash skills/stack-go/tests/run.sh`、`bash skills/stack-nextjs/tests/run.sh`。

`mac-widget-builder` 預設把 widget 寫到 `~/Widgets/<名稱>/`(倉庫外),需要在 host 核准寫入;各 widget 的資料來源網域也要核准。骨架自我測試:`bash skills/mac-widget-kit/tests/run.sh`。

短影音(`short-video-maker` 用 `short-video-kit`,錄網頁時另用 `web-dev-kit`,AI 素材與主題模式另用 `game-art-kit` 與區網 ComfyUI,設定同下方「遊戲美術」;ComfyUI 不可用時 repo / 影片模式照常運作):

```bash
ln -s "$(pwd)/agents/short-video-maker.md" ~/.claude/agents/short-video-maker.md
ln -s "$(pwd)/skills/short-video-kit" ~/.claude/skills/short-video-kit
brew install ffmpeg                       # 必要
brew install whisper-cpp                  # 影片模式(轉文字)才需要,另需模型檔:
mkdir -p ~/.cache/whisper && curl -L -o ~/.cache/whisper/ggml-large-v3-turbo.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin
brew install yt-dlp                       # 選用:影片網址輸入
```

成品預設寫到 `~/Movies/Shorts/<日期>-<名稱>/`(倉庫外),需要在 host 核准寫入。自我測試:`bash skills/short-video-kit/tests/run.sh`(SKIP 不算通過)。

遊戲美術(game-concept-artist + game-art-kit,另需 web-dev-kit 截參考網址):

```bash
ln -s "$(pwd)/agents/game-concept-artist.md" ~/.claude/agents/game-concept-artist.md
ln -s "$(pwd)/skills/game-art-kit" ~/.claude/skills/game-art-kit
mkdir -p ~/.config/game-art-kit && echo 'COMFYUI_URL=http://<ComfyUI 主機>:8188' > ~/.config/game-art-kit/config   # 本機設定,不進 git
```

ComfyUI 要用 `--listen` 啟動;macOS 要允許終端機 app 的「本機網路」權限。自我測試:`bash skills/game-art-kit/tests/run.sh`(離線)、`bash skills/game-art-kit/tests/run.sh --live`(實機 1 張小圖)。

遊戲前端(game-frontend-owner + stack-pixi,另需 web-dev-kit、game-art-kit(素材 schema)、acceptance-designer):

```bash
ln -s "$(pwd)/agents/game-frontend-owner.md" ~/.claude/agents/game-frontend-owner.md
ln -s "$(pwd)/skills/stack-pixi" ~/.claude/skills/stack-pixi
```

需要 Node.js ≥ 22(專案有指定 node 版本時,本機主版本 ≥ 專案指定的)、Google Chrome(Playwright 用系統 Chrome,不另外下載瀏覽器)。流程:acceptance-designer(簡報寫「遊戲前端」)起草情境 → game-frontend-owner 實作;缺素材時它寫 `assets.needs.json`,主 agent 交給 game-concept-artist 的「遊戲素材」模式,素材合併後再派 game-frontend-owner 接素材。自我測試:`bash skills/stack-pixi/tests/run.sh`(需要網路)。

資料庫審查(db-reviewer + db-review-kit):

```bash
ln -s "$(pwd)/agents/db-reviewer.md" ~/.claude/agents/db-reviewer.md
ln -s "$(pwd)/skills/db-review-kit" ~/.claude/skills/db-review-kit
```

需要本機 Docker(只接受本機 socket;遠端 `DOCKER_HOST` / context 會被拒絕)與 Go(≥ 專案 go.mod;goose CLI 與整合測試都用本機 Go,沿用 `~/go/pkg/mod` 模組快取)。主 agent 在合併 migration 或資料設計前派 db-reviewer;各專案的 DB 審查設定放 `<專案>/.claude/db-review.md`(只有固定標題,沒有預設值;沒有時 db-reviewer 會附設定草稿)。自我測試:`bash skills/db-review-kit/tests/run.sh`(會用 `postgres:18-alpine`,本來沒有就拉、測完刪除)。

GCP / GKE(gcp-guardian + gcp-ops-kit):

```bash
ln -s "$(pwd)/agents/gcp-guardian.md" ~/.claude/agents/gcp-guardian.md
ln -s "$(pwd)/skills/gcp-ops-kit" ~/.claude/skills/gcp-ops-kit
```

需要 python3、node、ruby(macOS 內建,用來解析 YAML);審查 / 計畫 / 變更另需使用者自己安裝 `gcloud`(`brew install --cask google-cloud-sdk`)與 `gke-gcloud-auth-plugin`,並建立 `~/.config/gcp-guardian/config`(權限 600,內容 `GG_SA_KEY_FILE=<SA 金鑰絕對路徑>`,金鑰也要 600;或用自己的 gcloud 帳號:`GG_AUTH=user` + `GG_ACCOUNT=<帳號>`,先自己 `gcloud auth login`;選填 `GG_DEFAULT_PROJECT`、`GG_REPORT_DIR`)。YAML 審查不需要 GCP。報告存本機 `~/gcp-guardian-reports/`,不進 git。流程:審查 / 計畫 → 使用者看報告逐條核准(「核准 C1、C3」)→ 主 agent 在計畫 run 目錄寫 `approval.json`(sha256 + 編號 + 使用者原話;gcp-guardian 自己寫不了)→ 帶 plan.json、sha256 與旗標「使用者已核准變更 C1, C3」派變更模式。自我測試:`skills/gcp-ops-kit/scripts/selftest.sh`(只用假 gcloud / kubectl)。

產品規格網頁(product-spec-writer + spec-site-kit):

```bash
ln -s "$(pwd)/agents/product-spec-writer.md" ~/.claude/agents/product-spec-writer.md
ln -s "$(pwd)/skills/spec-site-kit" ~/.claude/skills/spec-site-kit
```

需要 Node.js ≥ 22、git、Google Chrome(截圖用 web-dev-kit 的 `shot.mjs`,以 `file://` 開頁面)。網頁寫進各專案的 `docs/spec-site/`,commit 由主 agent 用 github-bot / gitlab-bot 做。功能超過 80 項時依模組分批派工(各批寫 `parts/<模組>.json`,最後一批合併)。自我測試:`bash skills/spec-site-kit/tests/run.sh`。

## 安裝 skill(全域連結)

把 skill 連到全域的 `~/.claude/skills`,所有專案都能用。連結要用絕對路徑:

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/agent-forge" ~/.claude/skills/agent-forge   # 在倉庫根目錄執行
```

不要再在專案的 `.claude/skills/` 建同名連結,否則會出現兩份 `agent-forge`。

## 更新與開發

- 直接改 `skills/agent-forge/` 底下的檔案。全域連結指向這個工作目錄,所以所有專案用的都是**目前切到的分支**,包含還沒合併的修改。
- playbook、角色、範本在下一個任務就會讀到新版;改到 `SKILL.md` 本身或新增 skill,要開新對話。
- 正式修改走分支 → PR → 合併進 `main`;平常使用時把倉庫留在 `main`。

GitHub 機器人(`github-bot`,設定步驟見 `skills/github-bot/SKILL.md`):

```bash
ln -s "$(pwd)/skills/github-bot" ~/.claude/skills/github-bot
bash skills/github-bot/tests/run.sh
```

GitLab 機器人(`gitlab-bot`,設定步驟見 `skills/gitlab-bot/SKILL.md`):

```bash
ln -s "$(pwd)/skills/gitlab-bot" ~/.claude/skills/gitlab-bot
bash skills/gitlab-bot/tests/run.sh
```
