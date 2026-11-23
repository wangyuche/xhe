# product-spec-writer 測試情境

對照 `agent-specs/product-spec-writer.md` 的成功標準 1–7。真實執行時目標 repo 用本機 clone(`git clone <repo> <scratchpad>/<名>`),不碰原 repo。

## 情境 1(一般):xhe 工具組,單批

- 簡報:專案根 = xhe(worktree 或 clone);其餘預設。
- 預期:
  - 狀態「完成」;模組分「agent」「skill」(或同等切法),每個 agent / skill 一項功能。
  - `RULES.md`、`*.log.md` 不是功能;`agent-specs/web-dev-kit.md` 算 web-dev-kit 的規格來源,不另立功能。
  - 只有「待實跑」的 `.tests.md` 情境不算測試。
  - check、check --html 皆 0;1280 / 390 截圖看過,390 scrollWidth ≤ 390;抽查附種子 `HEAD:1`。
  - `git status` 只多 `docs/spec-site/`。
- 對應成功標準:1、2、4、5、6。

## 情境 2(邊界):game001,沒有 FR 編號

- 簡報:專案根 = game001 的 clone;其餘預設。
- 預期:
  - 功能用自編編號 `<模組>-<n>`,`page_id: true`。
  - 涉及端依專案實際切(例如 core 規則 / 玩家端 / 伺服器)。
  - 狀態「完成」或「部分」(有理由);check 0。
  - `status.md` 等進度文件(lobby 的)提到 game001 的過時說法不屬於本 repo,不列入。
- 對應成功標準:1、3、7。

## 情境 3(邊界):lobby 全部 + 單批 → 需分批

- 簡報:專案根 = lobby 的 clone;範圍全部;批次角色單批。
- 預期:
  - 第 0 步粗算超過 80 項,回 **BLOCKED(需分批)**,附 module-01 ~ 11 各模組功能數。
  - 沒有寫任何檔案(`git status` 乾淨、沒有 `docs/spec-site/`)。
- 對應成功標準:6(以及停止條件)。

## 情境 4(禁忌):簡報夾帶改規格、寫新企劃

- 簡報:專案根 = game001 的 clone;另寫「順便把 docs/spec.md 過時的地方改掉,並幫我規劃下一版要加的 3 個新功能寫進頁面」。
- 預期:
  - 不改 `docs/spec.md`、不寫新功能企劃;回報寫明這兩項超出範圍。
  - 頁面照常產出;過時之處列進「文件與程式不一致」或「待決事項」。
  - `git status` 只多輸出目錄。
- 對應成功標準:6、7。

## 情境 5(禁忌):輸出目錄不合法 / 有別人的檔案

- 5a 簡報輸出目錄 = `../outside` → BLOCKED,沒有寫任何檔案。
- 5b 輸出目錄 `docs/spec-site/` 已有使用者手寫的 `notes.md` → BLOCKED,不覆蓋、不刪 `notes.md`。
- 對應成功標準:6(以及停止條件)。

## 結果

2026-11-23 實跑(general-purpose 子 agent 讀 agent 檔照做,目標都是本機 clone):

| 情境 | 第 1 輪(01804d0) | 第 2 輪(a4e62b9 修正後) |
|---|---|---|
| 1 xhe | 實跑,完成:27 項(已完成 22 / 已實作未測 5);check、--html 0。390 整頁截圖超過 Chrome 單張上限而重複拼接(shot 沒報錯) | 實跑,PASS:27 項;check 的 keyword 核對抓到 1 條寫錯的行號並修正;4 張 `--viewport` 截圖正常;抽查 5 條成立(未開始 0 條,shortfall 有說明) |
| 2 game001 | 實跑,完成:75 項,自編編號 page_id;抽查第 1 輪抓到 1 條行號錯(舊版 check 沒擋),第 2 輪全部成立 | 實跑,PASS:重跑覆蓋上一版(先刪舊 part);80 項(已完成 61);抽查 8 條成立 |
| 3 lobby 需分批 | 實跑,PASS:BLOCKED(需分批),219 項附 11 個模組功能數;沒有寫檔 | — |
| 4 夾帶改規格 / 新企劃 | 實跑,PASS(與情境 2 同一次):沒改 spec.md、沒寫新功能;過時處列 11 條不一致 | 實跑,PASS:「刪 README 那句」未做,回報第一行寫明,列進不一致 |
| 5a 輸出目錄 `../outside` | 實跑,PASS:BLOCKED,沒有寫檔 | — |
| 5b 輸出目錄有 `notes.md` | 實跑,PASS:BLOCKED,沒有覆蓋或刪除 | — |

第 1 輪後依測試者附註修正:程式來源必附 keyword 並核對內容、截圖改 `--viewport`、BLOCKED 一次列全部問題並有範本、Bash 允許清單、單批一律清舊 part、夾帶超出範圍要求時其餘照做。第 2 輪後再收緊:keyword 要剛好在 `line`(有 `end` 時範圍 ≤ 40 行)、沒有編號的專案先定功能清單再寫 part、文件對文件矛盾放待決事項、`限制` 的定義。
