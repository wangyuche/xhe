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

任務不屬於任何一份時,先告訴使用者,不要硬套;需要時再提議新增 playbook。

## 原則

1. **先可信,再產出。** 沒有證據不算完成。缺口(缺證據、無法判定)不算通過。
2. **流程固定。** 照 playbook 的順序走,不跳關。
3. **做的人不審自己。** 規格由 `spec-reviewer` 審,成品由 `agent-tester` 測,多 agent 時由獨立 verifier 驗收。
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
