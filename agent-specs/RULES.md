# 規則表

每條規則成對記錄「規則」與「由什麼強制」。強制方式由強到弱:結構 > 檢查 > 測試 > 僅文字。
「僅文字」的規則若錯誤再發生,視為重複,下次要升級成更高層的強制方式。
規則對應的錯誤已經不可能發生時,移除該規則。

## tw-stock-analyst

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 交易時間內先用 `fugle.sh` 抓即時價再下結論;跌破支撐 / 突破壓力寫在結論第一行 | 測試(tests 情境 5)+ 成功標準 1 + 文字(附失敗範例) | 2026-11-16 主 agent 大盤判斷「平盤開出」實際跌 2.9%;同日舊版子 agent 用 Yahoo + mis.twse、跌破 MA20 只寫在最後 |
| 不用 `mis.twse.com.tw`(不在沙盒允許清單,會跳提示) | 僅文字 | 2026-11-16 舊版子 agent 測試 |
| 大盤背景必附台指期夜盤實際數字(期交所),不能只看新聞標題 | 測試(tests 情境 1)+ 成功標準 1 + 文字(附失敗範例) | 2026-11-15 主 agent 憑標題估跳空跌 200–400 點;2026-11-16 舊版子 agent 報告無夜盤 |
| 報告必含籌碼面:近 10 日三大法人、融資券、借券賣出餘額;要求時加集保大戶 | 成功標準 1(九段落)+ 測試(tests 情境 1、1b) | 2026-11-15 分析 3055 後使用者另外要求補借券、集保大戶。只發生 1 次,**使用者 2026-11-16 指示直接加入,不等第二次** |
| 子 agent 不寫任何檔案、不用 `curl -o` | 文字 + 工具限制(只有 Bash/WebSearch/WebFetch/Read,無 Write/Edit) | 建立時就有;也因此不需要「指令中不要寫 `/dev/null`」的規則(主 agent 11/15 兩次因 `-o /dev/null` 跳提示,子 agent 不可能發生) |

## 主 agent(Telegram 群組回覆)

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 三大法人個股買賣超排行:買超與賣超都要同時列「張數」與「金額(億)」,依金額排序;金額 = 買賣超股數 × 當日收盤價(估算,要標明) | 結構(`~/.claude/tg/inst_rank.py <T86.json> <STOCK_DAY_ALL.csv> [N]`)+ 文字 | 2026-11-16 群組回覆外資賣超只列張數、依張數排序,中鋼排第 1、台積電排第 7,實際依金額台積電 -187.5 億居首、中鋼不在前 10;外資買超也被誤讀成「轉進金融航運」。使用者 2026-11-16 指示直接加入 |

## mac-widget-builder

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| widget.json 打包進 `.app/Contents/Resources/` 並優先讀;state.json 存 `~/Library/Application Support/com.widget.<name>/` | 結構(kit `build.sh`、`Support.swift`、`WindowHost.swift`)+ 檢查(kit `tests/run.sh`「widget.json 已打包進 bundle」) | 2026-11-16 ClaudeTokenWidget 專案在 `/Volumes/ariesdisk`,終端機 `--once` 通過、桌面上卻「無資料:沒權限讀 widget.json」 |
| 驗證要含 GUI 啟動情境:`open -n -W --stdout … --args --once` | 檢查(工作流程 4b + 成功標準 2) | 同上;只用終端機驗證,看不到權限差異 |
| 桌面浮窗左鍵按下直接 `performDrag` | 結構(kit `DraggableHostingView.mouseDown`) | 2026-11-16 使用者回報拖不動(SwiftUI 吃掉 mouseDown,`isMovableByWindowBackground` 無效) |
| 讀其他 app 的鑰匙圈憑證要有旗標「使用者已同意讀取鑰匙圈項目「<服務>」」;經 `/usr/bin/security`,不輸出、不寫檔 | 旗標 + 測試(tests 情境 6、6b)+ 成功標準 7 | 2026-11-16 使用者同意讀 Claude Code OAuth 憑證,子 agent 無對應旗標而 BLOCKED,主 agent 自行完成。只發生 1 次,**使用者 2026-11-16 指示直接改進** |

## 待辦(暫緩)

只發生過 1 次,依 `improve.md`「同一類錯誤發生兩次才算教訓」暫緩。再發生一次就加進 agent。

| 項目 | 發生紀錄 | 再發生時的做法 |
|---|---|---|
| mac-widget-builder 交叉比對不能用 `python3` | 2026-11-16 主 agent 要求 python3 腳本比對,子 agent 改用 zsh + grep 達成,結果正確 | 再因為不能解析 JSON 而比對失敗時,加入 `python3 -I`(唯讀)或改用 `plutil -extract` |
| 主 agent 直接改 widget 時沒照 kit 規則(多加 .swift 檔、選單列 13 字) | 2026-11-16 主 agent 加 `Quota.swift`、`✻ 18% · 34.1M`,自行發現後合併並改成 11 字 | 再發生時,在 kit `SKILL.md` 開頭加「主 agent 修改也要跑 `tests` 的骨架 diff 與 menubar-length 檢查」 |
| 子 agent 執行第 4b 步 `open -n -W --stdout` 得到 `-10810` | 2026-11-16 加 Sessions 時(同一天稍早的重測可以跑);主 agent 在自己的 shell 重跑 4b 通過 | 再發生時,在 4b 加「`-10810` 是執行環境限制:回報指令、狀態不因此判 ISSUES,由主 agent 代跑」 |
| 測試時反覆跑 `--once` / snapshot,把有限流的外部 API 打到 429 | 2026-11-16 加 Sessions 時,額度 API 被打到 429(Retry-After 216 秒);主 agent 補上 429 退避與沿用舊值 | 再發生時,在工作流程加「外部 API 有限流時,驗證期間 `--once` / snapshot 合計不超過 N 次」,並要求 Provider 處理 429 |
| PDF 附件要連圖表頁一起讀(Read `pages`) | 2026-11-15 台積電法說會簡報,當時沒裝 poppler,圖表頁讀不到(環境問題,已由使用者安裝 poppler 解決) | 子 agent 漏讀圖表頁時,加進工作流程第 6 步 |
