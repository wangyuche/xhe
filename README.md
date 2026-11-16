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

## Agents

每個 agent 放在 `agents/<名稱>.md`,規格放在 `agent-specs/<名稱>.md`。

| agent | 用途 |
|---|---|
| `tw-stock-analyst` | 台股個股分析:基本面、合理價、時事、技術面、1–2 週價位預測(只讀、不寫檔) |
| `mac-widget-builder` | Mac 桌面 / 選單列 widget:SwiftUI + AppKit,只用 Command Line Tools 編譯,實際取資料與預覽驗證 |
| `acceptance-designer` | 網站 feature 的驗收情境設計(只讀):編號情境、測試層級、待決產品問題 |
| `frontend-owner` | 網站前端(React / Next.js):依驗收情境實作與測試、截圖驗證 |
| `backend-owner` | 網站後端(Go):實作、維護 OpenAPI 契約、httptest 與 curl 驗證;有「僅契約」模式 |
| `integration-verifier` | 網站整合驗證(只讀):真實前後端一起跑,轉發、截圖、E2E、情境對照 |

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

需要 Node.js ≥ 24.18、Go ≥ 1.26(`brew install node go`)、Google Chrome;PostgreSQL 選用 Docker。流程:acceptance-designer 起草情境 → 使用者回答待決問題 → (平行時先 backend-owner「模式:僅契約」)→ frontend-owner / backend-owner 各在獨立 worktree 實作 → 主 agent commit 到 `agent/<agent>/<task>` 分支 → 單位 verifier → 合併到整合分支 → integration-verifier PASS → 主 agent 開 MR / PR 並以驗證過的 SHA 合併(GitLab:`glab mr merge <MR> --sha <SHA>`,SHA 不符會被拒絕;沒有遠端時本地合併);刪分支、force-push、部署仍先問使用者。GitLab:建一個專用機器人使用者(例如 `claude-bot`,Regular、非 admin),以 Developer 加入網站專案或 group,用它的 Personal Access Token(scopes 只有 `api` + `write_repository`)執行 `glab auth login`;一個 glab 登入即可跨專案。各專案 `main` 設為 No one 可 push、Developers + Maintainers 可 merge。自我測試:`bash skills/web-dev-kit/tests/run.sh`、`bash skills/stack-go/tests/run.sh`、`bash skills/stack-nextjs/tests/run.sh`。

`mac-widget-builder` 預設把 widget 寫到 `~/Widgets/<名稱>/`(倉庫外),需要在 host 核准寫入;各 widget 的資料來源網域也要核准。骨架自我測試:`bash skills/mac-widget-kit/tests/run.sh`。

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
