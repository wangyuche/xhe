# xhe

我的 Claude Code skill 倉庫。每個 skill 放在 `skills/<名稱>/SKILL.md`。

| skill | 用途 |
|---|---|
| `agent-forge` | 造專業 agent、協調多個 agent 同時做事、依使用成果改進 agent |
| `tw-stock-calc` | 台股技術指標與合理價的固定計算腳本(tw-stock-analyst 使用) |
| `mac-widget-kit` | Mac 桌面浮窗 / 選單列 widget 骨架與腳本,免 Xcode(mac-widget-builder 使用) |
| `web-dev-kit` | 網站驗證腳本:啟停 dev server、Chrome 整頁截圖、轉發比對、範圍檢查、秘密掃描、本機 PostgreSQL |
| `stack-react` | React 元件與 Vitest 測試規則 |
| `stack-nextjs` | Next.js 16 前端規則與骨架(轉發、契約型別、Prism mock、Playwright) |
| `stack-go` | Go 後端規則與骨架(路由表、OpenAPI 3.0.3 契約測試、goose migration) |
| `github-bot` | 以機器人身分(GitHub App 或機器人帳號)commit、push 功能分支、開 PR,自己 code review 沒問題就以 review 過的 SHA 合併(只限沒有 CI 的 repo;不直接推 main) |
| `gitlab-bot` | 在自建 GitLab(或 gitlab.com)commit、push 功能分支、開 MR,review 沒問題以 review 過的 SHA 合併(只限沒有 CI 的專案;不直接推 main);多專案共用一筆鑰匙圈 token(需 `api` + `write_repository`) |
| `short-video-kit` | 9:16 短影音腳本:轉文字、停頓偵測、say 旁白、卡片 / 字幕渲染、錄網頁、ffmpeg 合成、規格驗證(short-video-maker 使用) |
| `game-art-kit` | 區網 ComfyUI 出圖腳本:check、上傳參考圖、送 workflow 輪詢下載(不在伺服器留檔)、workflow 骨架、拼分鏡表(game-concept-artist 使用);位址放 `~/.config/game-art-kit/config` |

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
| `short-video-maker` | 短影音:GitHub repo 或影片 → 1080×1920、≤60 秒 MP4(圖卡 / 錄網頁 / 挑精華 / 去停頓),旁白與字幕,實際驗證規格與響度 |
| `game-concept-artist` | 遊戲示意圖與分鏡:ComfyUI 出圖,照各遊戲 `art/STYLE.md`,角色多張一致(參考圖編輯模型),逐張看圖;風格試作 / 定稿 / 角色定裝 / 一般 |

安裝(全域連結,在倉庫根目錄執行):

```bash
mkdir -p ~/.claude/agents
ln -s "$(pwd)/agents/tw-stock-analyst.md" ~/.claude/agents/tw-stock-analyst.md
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/tw-stock-calc" ~/.claude/skills/tw-stock-calc   # agent 依賴的計算腳本
ln -s "$(pwd)/agents/mac-widget-builder.md" ~/.claude/agents/mac-widget-builder.md
ln -s "$(pwd)/skills/mac-widget-kit" ~/.claude/skills/mac-widget-kit  # widget 骨架與腳本
```

`tw-stock-analyst` 需要在 host 核准規格中列出的網域;可選擇設定環境變數 `FINMIND_TOKEN` 提高 FinMind 額度。

網站 agent 組(安裝與流程):

```bash
for a in acceptance-designer frontend-owner backend-owner integration-verifier; do ln -s "$(pwd)/agents/$a.md" ~/.claude/agents/$a.md; done
for k in web-dev-kit stack-react stack-nextjs stack-go; do ln -s "$(pwd)/skills/$k" ~/.claude/skills/$k; done
```

需要 Node.js ≥ 24.18、Go ≥ 1.26(`brew install node go`)、Google Chrome;PostgreSQL 選用 Docker。流程:(新前端先由主 agent 問使用者風格,派 frontend-owner「模式:僅設計規範」寫 `design/DESIGN.md` 並 commit;不需要時派工寫「不需要設計規範」)→ acceptance-designer 起草情境 → 使用者回答待決問題 → (平行時先 backend-owner「模式:僅契約」)→ frontend-owner / backend-owner 各在獨立 worktree 實作 → 主 agent commit 到 `agent/<agent>/<task>` 分支 → 單位 verifier → 合併到整合分支 → integration-verifier PASS → 主 agent 開 MR / PR 並以驗證過的 SHA 合併(GitLab:`glab mr merge <MR> --sha <SHA>`,SHA 不符會被拒絕;沒有遠端時本地合併);刪分支、force-push、部署仍先問使用者。GitLab:建一個專用機器人使用者(例如 `claude-bot`,Regular、非 admin),以 Developer 加入網站專案或 group,用它的 Personal Access Token(scopes 只有 `api` + `write_repository`)執行 `glab auth login`;一個 glab 登入即可跨專案。各專案 `main` 設為 No one 可 push、Developers + Maintainers 可 merge。自我測試:`bash skills/web-dev-kit/tests/run.sh`、`bash skills/stack-go/tests/run.sh`、`bash skills/stack-nextjs/tests/run.sh`。

`mac-widget-builder` 預設把 widget 寫到 `~/Widgets/<名稱>/`(倉庫外),需要在 host 核准寫入;各 widget 的資料來源網域也要核准。骨架自我測試:`bash skills/mac-widget-kit/tests/run.sh`。

短影音(`short-video-maker` 用 `short-video-kit`,錄網頁時另用 `web-dev-kit`):

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
