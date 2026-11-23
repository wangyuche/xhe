---
name: spec-site-kit
description: 產品規格網頁的固定腳本:spec.schema.json(模組 part、專案資訊、合併後 spec 的格式)、check.mjs(依狀態檢查必填來源:已完成每端要有程式與測試、未開始的關鍵字在程式搜尋範圍內 git grep 必須找不到;來源檔要在 git 追蹤中且行號在範圍內;commit 等於 HEAD;統計一致;禁止本機絕對路徑 / 私有 IP / 秘密樣式;--html 核對產生標記與 spec.json 雜湊、無外部資源;--self-test 檢查 kit、web-dev-kit shot.mjs 與 Chrome)、merge.mjs(合併 parts/*.json,commit 不是 HEAD 的模組要重做)、render.mjs(單一自足 HTML,無 JavaScript、深淺色跟系統、只有固定結構沒有品牌樣式)、sample.mjs(以 commit + 輪次為種子的可重現抽查)。product-spec-writer 整理產品規格頁時使用;任何要把專案現況整理成有來源佐證的規格網頁的情境也可用。
---

# spec-site-kit

`<kit>` = 這個 skill 的目錄(`~/.claude/skills/spec-site-kit`)。只用 Node 內建模組(≥ 22)與 git。截圖用 web-dev-kit 的 `shot.mjs`(支援 `file://`)。

**沒有預設內容與樣式**:頁面只固定段落、欄位與 5 種狀態;產品名稱、模組切法、說明文字全部來自專案本身。

## 目錄與流程

```
<專案根>/<輸出目錄,預設 docs/spec-site>/
  parts/_project.json   產品資訊、讀過的來源、不屬於單一模組的段落(只由單批 / 分批最後一批寫;平行批次把跨模組項目寫進自己的 part)
  parts/<模組>.json     一個模組一檔(每做完一個模組就寫)
  spec.json             merge.mjs 產生
  index.html            render.mjs 產生
```

```bash
node <kit>/scripts/check.mjs --self-test [--shot <shot.mjs>]          # kit、shot.mjs、Chrome、node ≥ 22、git
node <kit>/scripts/check.mjs --part <輸出目錄>/parts/<模組>.json --root <專案根> [--no-spec-docs]   # 每個模組寫完就跑;沒有 _project.json 時 no_spec_docs 看旗標
node <kit>/scripts/check.mjs --part <輸出目錄>/parts/_project.json --root <專案根>
node <kit>/scripts/merge.mjs <輸出目錄>                                 # → spec.json(含 branch、dirty、generated_at、stats)
node <kit>/scripts/check.mjs <輸出目錄>/spec.json --root <專案根>
node <kit>/scripts/render.mjs <輸出目錄>/spec.json                      # → index.html
node <kit>/scripts/check.mjs --html <輸出目錄>/index.html
node <kit>/scripts/sample.mjs <輸出目錄>/spec.json [--round 2]          # 抽 5 條已完成、3 條未開始;不足時 shortfall 說明
# 規格頁很長,整頁截圖會超過 Chrome 單張上限而重複拼接:用 --viewport 分段截(scrollWidth 仍量整份文件)
node ~/.claude/skills/web-dev-kit/scripts/shot.mjs "file://<絕對路徑>/index.html" 1280 800 <暫存>/d.png --viewport
node ~/.claude/skills/web-dev-kit/scripts/shot.mjs "file://<絕對路徑>/index.html" 390 844 <暫存>/m.png --mobile --viewport
node ~/.claude/skills/web-dev-kit/scripts/shot.mjs "file://<絕對路徑>/index.html#modules" 390 844 <暫存>/m-modules.png --mobile --viewport
node ~/.claude/skills/web-dev-kit/scripts/shot.mjs "file://<絕對路徑>/index.html#pending" 390 844 <暫存>/m-pending.png --mobile --viewport
```

所有腳本 stdout 一行 JSON;結束碼 0 通過、1 不通過、2 用法錯誤。

## 資料格式(完整定義在 `schemas/spec.schema.json`)

來源 `source`:`{kind, path, line, end?, side?, match?, keyword?, note?}`
- `kind`:`規格` / `程式` / `測試` / `進度` / `其他`。`path` 相對專案根、必須是 git 追蹤檔;`line` 對照**目前工作目錄**的內容。
- `程式`、`測試` 要有 `side`(必須是功能 `sides` 之一;端對端測試可標 `跨端`,算涵蓋每一端)。`測試` 要有 `match`:`引用編號`(測試直接寫功能編號,優先)或 `關鍵字`(附 `keyword`)。
- **內容核對**:`程式` 來源必附 `keyword`(那幾行裡的函式名、常數、路由或 UI 字串)。有 `keyword` 的任何來源,keyword 要出現在 `line` 那一行(有 `end` 時 `line` ~ `end`,範圍最多 40 行);挑那一行獨有的字串,不要用太泛的詞;`引用編號` 的測試沒附 keyword 時,找功能編號。找不到 = 行號或 keyword 錯,check 不過。

功能 `feature`:`{id, page_id?, name, summary, sides[], status, reason?, keywords?, sources[], notes?[]}`
- `id` 沿用文件編號(可有字母後綴,例 `FR-091A`、`FR-RPS-12`);文件沒有編號時自編 `<模組>-<n>` 並設 `page_id: true`。
- `notes`:`{type: 限制 | 開發中, text, branch?, sources[]}`。

part:`{kit: "spec-site-kit/1", commit, module{id, name, summary, order?, sources}, code_paths[], exclude_paths[], features[], flows?, rules?, pending?, mismatches?, out_of_scope?, tech?}`
- `module.order`:頁面上的模組順序(照規格章節);沒寫的排最後,同序依 id。
- `code_paths`:程式所在目錄(例 lobby `server/ src/ admin/`)。`exclude_paths`:規格 / 進度文件所在處(例 lobby `docs/`、xhe `agent-specs/ README.md`)。驗證「未開始」只在 `code_paths` 搜、排除 `exclude_paths` 與輸出目錄;**不會**一律排除 `*.md`(xhe 的程式本身就是 `.md`)。

段落:`flows{name, steps[], sources}`、`rules / out_of_scope / tech{text, sources}`、`pending{text, decider: 使用者 | 開發, sources}`、`mismatches{text, doc[], code[], keywords?, origin?}`(`code` 可放 `程式` / `測試` / `其他` 來源,`side` 可省;`程式` 要 keyword,`引用編號` 的測試要附 keyword 寫要核對的編號;程式那邊找不到時 `code: []` 並附 `keywords`,check 會在程式搜尋範圍內 grep,找得到就不過;`_project` 的不一致逐模組用各自的 `code_paths` / `exclude_paths` 搜)。

## check 依狀態的規則

| 狀態 | 必須 |
|---|---|
| 已完成 | 有 `規格`;每個 `sides` 都有 `程式` 與 `測試`;不可有 `限制` 備註 |
| 已實作未測 | 有 `規格`(`no_spec_docs` 時免);每個 side 都有 `程式`;至少一端缺 `測試` 或有 `限制` 備註(否則應判已完成;只有部分端有程式應判無法判定) |
| 未開始 | 有 `規格`;沒有 `程式`;有 `keywords`,且每個在程式搜尋範圍內 `git grep -i -F` 找不到 |
| 不做 | 有 `reason`(例「已作廢 → FR-031」「backlog」)與至少一條來源 |
| 無法判定 | 有 `reason` |

`no_spec_docs: true` 時不可有「已完成」「未開始」。

## 注意

- 內容掃描擋:本機絕對路徑(`/Users`、`/Volumes`、`/private`、`/tmp`、`/root`、`/home/<名>/`;keyword 裡像路由的 `/home/…` 放行)、私有 IP、`.local` / `.lan` / `.internal` / `.home.arpa` 主機名、常見 token / 私鑰樣式。
- `check --html` 擋 `<script>`、`on*` 事件屬性、`javascript:`、外部資源標籤、`<style>` 裡的 `@import` / `url()`。
- 只寫輸出目錄;check 只讀(`git ls-files`、`git grep`、`git rev-parse`)。
- `git grep` 用 `-I`(跳過圖片、音檔等二進位檔)、`-F -i`。
- spec.json 的 `dirty` 判斷時排除輸出目錄(輸出目錄本來就會有未追蹤 / 已修改的檔案)。
- part 的 `commit` 必須等於 HEAD,merge 才會合併;HEAD 變了就要重做那些模組。
- `index.html` 只能由 render 產生;改 `spec.json` 後要重新 render(`check --html` 會抓雜湊不符)。
- 自我測試:`bash <kit>/tests/run.sh`(有 Chrome 時含 file:// 截圖)。
