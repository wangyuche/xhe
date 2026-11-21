---
name: agent-forge
description: 造專業 agent、協調多個 agent 同時做事、並依使用成果改進 agent。當使用者說「幫我做一個 agent」「建立專業 agent」「我需要一個能做 X 的 agent」、要多個 agent 協作、或說「reflect」「糾正 agent」時使用。
---

# agent-forge

入口 skill。依任務類型分流到對應的 playbook,規則細節都在 playbook 裡。結構參考 pstack 的 `poteto-mode` 加 `playbooks/`。

## 分流

| 使用者要做的事 | 讀這份 playbook |
|---|---|
| 造一個新的專業 agent | `playbooks/create-agent.md` |
| 多個 agent 同時做事、派工、驗收、合併 | `playbooks/multi-agent.md` |
| 回頭看 agent 的成果、被糾正、`reflect` | `playbooks/improve.md` |
| 設計方向不確定,要多個候選比較 | `playbooks/arena.md` |

只讀這次要用的 playbook,要用就完整讀,不要只讀片段(依據 pstack poteto-mode)。

任務不屬於任何一份時,先告訴使用者,不要硬套;需要時再提議新增 playbook。

**每個任務開始前,都用 Read 重新讀對應的 playbook**,不要靠之前讀過的記憶。這份 `SKILL.md` 在一個對話裡只會載入一次,但 playbook 每次讀都是最新版,xhe 的 `main` 更新後下個任務就會用到新規則。

## 檔案位置

- **skill 目錄**(載入時會給「Base directory for this skill」):`playbooks/`、`roles/`、`templates/` 都在這裡。這個目錄是 xhe repo 的連結(`~/.claude/skills/agent-forge` → xhe),**不要直接改**,改法見下方。
- **產出**一律寫在**目前專案的根目錄**底下:`.claude/agents/`、`.claude/agent-specs/`、`.claude/skills/`。不要寫進 skill 目錄。
- **版本指紋:** 對 skill 目錄算一次內容雜湊,用來判斷規則有沒有變:`find <skill 目錄> -type f -name '*.md' | sort | xargs shasum | shasum`。回報時可附上前 8 碼。

## 派出審查角色

審查者和測試者是 `roles/` 裡的角色檔,不是有名字的 agent。派法:

- 用唯讀的 subagent 類型(`subagent_type: "Explore"`),用工具限制保證它們不改檔案。
- 提示詞第一句:「先用 Read 完整讀完 `<skill 目錄>/roles/<角色>.md`,照它的規則做。」接著附上它需要的檔案路徑。
- 不要把角色檔內容貼進提示詞,傳路徑就好。

## 修改 agent-forge 本身

skill 目錄直接連到 xhe repo,只有合併進 `main` 的版本才算數。要改 agent-forge 本身(playbook、角色、範本):

1. 在其他專案裡,只**提出**改動清單,不要直接修改 skill 目錄。
2. 實際修改在 xhe repo 開分支、commit、開 PR,審查後合併。
3. 合併後,xhe 本機的工作目錄回到 `main` 並 `git pull`,連結就會指到新版(第一次安裝:`ln -s <xhe>/skills/agent-forge ~/.claude/skills/agent-forge`)。
4. 改到 `SKILL.md` 本身時,要開新對話才會生效;只改 playbook、角色、範本的話,下個任務就會生效。

## 原則

1. **先可信,再產出。** 沒有證據不算完成。缺口(缺證據、無法判定)不算通過。
2. **流程固定。** 照 playbook 的順序走,不跳關。
3. **做的人不審自己。** 規格由 `roles/spec-reviewer.md` 審,成品由 `roles/agent-tester.md` 測,多 agent 時由獨立 verifier 驗收。
4. **先分類再問。** 查得到的事自己查,只問真正的產品或偏好選擇。
5. **用繁體中文**與使用者溝通,產出的 agent 預設也用繁體中文,除非使用者另有指定。

## 什麼時候要停下來問使用者

- 規格寫好後,要使用者確認才開始生成。
- 不可逆或對外的動作:force-push、刪分支、部署、刪資料、對外發訊息。
- 沒有實驗能決定的產品或偏好選擇。
- 要套用改進清單時。
- 重新規劃後仍走不通的死路。

可逆的事(本地 commit、重試、rebase)不問。

## 注意

- 不要覆蓋已存在的 agent 檔案。名稱衝突時先問使用者。
- 不要在使用者確認規格前就動手生成。
- 回報時據實說明,測試沒過就說沒過。
- 標「自訂」的規則是本專案自己加的,不是 pstack 原文。
