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
| 子 agent 不寫任何檔案、不用 `curl -o` | 僅文字(工具清單沒有 Write/Edit,但有 Bash:`curl -o`、`>` 重新導向、python 寫檔都擋不住;只有不含 Write/Edit/Bash 的 agent,例如 acceptance-designer,才是工具強制) | 建立時就有。2026-11-22 全專案 review 更正:原本寫成「工具限制」強制,高估了。主 agent 11/15 兩次因 `-o /dev/null` 跳提示,子 agent 同樣可能發生,只靠指示避免 |

## 主 agent(Telegram 群組回覆)

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 三大法人個股買賣超排行:買超與賣超都要同時列「張數」與「金額(億)」,依金額排序;金額 = 買賣超股數 × 當日收盤價(估算,要標明) | 結構(`~/.claude/tg/inst_rank.py <T86.json> <STOCK_DAY_ALL.csv> [N]`)+ 文字 | 2026-11-16 群組回覆外資賣超只列張數、依張數排序,中鋼排第 1、台積電排第 7,實際依金額台積電 -187.5 億居首、中鋼不在前 10;外資買超也被誤讀成「轉進金融航運」。使用者 2026-11-16 指示直接加入 |
| 回答夜盤、盤前、大盤開盤（含跳空）問題時,必附前一晚美股收盤:四大指數(道瓊、S&P 500、那斯達克、費半)、輝達、台積電 ADR 與大幅波動個股;先查美股再說原因,不能寫「原因查不到」 | 結構(`~/.claude/tg/us_close.sh <symbols…>`)+ 文字 | 2026-11-18 早盤跳空 +628 點時回「查不到原因」,其實是輝達財報;2026-11-20 夜盤 -500 點又說原因不明,一查美股四大指數都跌 2% 以上、台積電 ADR -2.9%。使用者 2026-11-20 指示「台股跟美股有很高關係,寫進改善」 |

## frontend-owner

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 前端風格寫在各專案的 `design/DESIGN.md`(僅設計規範模式依風格描述從頭寫,只固定 8 個標題,不提供預設範本);一般模式照它做、截圖逐節對照;新專案沒有它就 BLOCKED,除非簡報寫「不需要設計規範」 | 測試(tests 情境 6、8 已實跑;情境 7「一般模式照 DESIGN.md」待實跑)+ 成功標準 11、12 + 文字 | 使用者 2026-11-21 要求;同日否決帶預設值的 DESIGN / CSS token 範本(「每個專案都不同,你做這個模板幹嘛」) |

## mac-widget-builder

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| widget.json 打包進 `.app/Contents/Resources/` 並優先讀;state.json 存 `~/Library/Application Support/com.widget.<name>/` | 結構(kit `build.sh`、`Support.swift`、`WindowHost.swift`)+ 檢查(kit `tests/run.sh`「widget.json 已打包進 bundle」) | 2026-11-16 ClaudeTokenWidget 專案在 `/Volumes/ariesdisk`,終端機 `--once` 通過、桌面上卻「無資料:沒權限讀 widget.json」 |
| 驗證要含 GUI 啟動情境:`open -n -W --stdout … --args --once` | 檢查(工作流程 4b + 成功標準 2) | 同上;只用終端機驗證,看不到權限差異 |
| 桌面浮窗左鍵按下直接 `performDrag` | 結構(kit `DraggableHostingView.mouseDown`) | 2026-11-16 使用者回報拖不動(SwiftUI 吃掉 mouseDown,`isMovableByWindowBackground` 無效) |
| 讀其他 app 的鑰匙圈憑證要有旗標「使用者已同意讀取鑰匙圈項目「<服務>」」;經 `/usr/bin/security`,不輸出、不寫檔 | 旗標 + 測試(tests 情境 6、6b)+ 成功標準 7 | 2026-11-16 使用者同意讀 Claude Code OAuth 憑證,子 agent 無對應旗標而 BLOCKED,主 agent 自行完成。只發生 1 次,**使用者 2026-11-16 指示直接改進** |

## short-video-maker

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| kit 沒有預設配色:用到 theme 的卡片、headline 缺 theme 結束碼 2,置頂鏡頭缺 `theme.bg` 結束碼 2;agent 依 repo logo / 網站主色或影片畫面選色,`script.md` 寫配色與來源 | 結構(render.mjs / compose.mjs 檢查)+ 測試(kit tests、tests 情境 7)+ 成功標準 11 | 使用者 2026-11-21 指示:各專案不同,不要共用模板(原本寫死深藍 / 天藍,每支影片同色) |
| 未 commit 檔案指紋要在 repo 根目錄算:`(cd <repo> && git ls-files -m -o --exclude-standard -z \| xargs -0 shasum \| shasum)` | 文字(agent 第 0 步)+ 說明空雜湊 `da39a3ee…` 的意義 | 2026-11-17 測試時在 repo 外執行,得到空輸入雜湊,比對永遠一致 |
| 本機 repo clone 用 `file://` | 文字 | 2026-11-17 `--depth is ignored in local clones` |
| repo-cards 封面不疊標題卡 | 結構(render.mjs `cover` 可不放圖片)+ 文字 | 2026-11-17 封面兩層標題 |
| 字幕先試單行、兩行優先在標點斷、連字號不斷 | 結構(render.mjs)+ 測試 | 2026-11-17 「web-dev-/kit」「按新/增」 |
| 旁白模式的橫式錄影鏡頭置頂、不裁左右;用 `region` 逐鏡頭放大，放大後會壓到字幕區就結束碼 6 | 結構(compose.mjs 置頂 + `region`)+ 測試(kit tests 7b:第二版設定 → 結束碼 6;UI 下緣 ≤ 1280、字幕區是底色) | 2026-11-18 craft-anything 第二版整支 `fit: crop`,右側欄與函式名稱被切。原規則「逐張確認…沒有被裁切」只是文字，錯誤仍發生，依 improve.md 視為重複，升級 |
| 每個鏡頭的中點與結尾都要擷圖並看過;講到的元素被切或被字幕蓋住要重做，不能寫進已知限制就判 PASS | 檢查(verify.sh `--scenes` 必填、鏡頭表要涵蓋整支)+ 測試(kit tests 7)+ 文字(附失敗範例) | 同上;第二版 25/50/75% 擷圖漏看鏡頭，agent 看到裁切仍回 PASS |

## acceptance-designer

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 第 11 個固定面向「並發與資源成長」:每個寫入端點都有結論;有次數限制時「擋」與「放」兩條 `並發` 情境;會累積的表要有清理情境;整數極大值 → 400 | 結構(面向表必填、類型 `並發`)+ 成功標準 1 + 測試(tests 情境 5,2026-11-21 實跑通過)+ 文字(附失敗範例) | 2026-11-21 fortest 登入 + RBAC:第一版 30 條情境沒有並發,4 輪 code review 才補出 8 項 |

## backend-owner

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 有 `並發` 情境或涉及先檢查再寫入、計數 / 鎖定、不變量、會累積的表 → 先讀 `stack-go/references/concurrency.md`;並發測試用 Hook 做確定性交錯、附反向驗證、擋與放都測 | 成功標準 11 + 測試(tests 情境 6,待實跑)+ 文字(reference 附失敗範例) | 2026-11-21 fortest:並發猜密碼、互相降級、交易內重驗、清理死結等,4 輪 review 共 6 次 |
| 修正模式:每個修正補「不該被擋的正向路徑」測試,受影響寫入端點重跑 `concurrency.mjs` | 成功標準 11 + 文字(附失敗範例) | 2026-11-21 fortest:第 2 輪「預約額度」讓並發正確登入收到 423;同輪交易內清理造成第 3 輪死結(修正帶出回歸 2 次) |
| 僅契約模式回報附「端點驗證表」(成功 / 錯誤範例、冪等、經前端轉發) | 成功標準 12 + 測試(tests 情境 7,待實跑) | 2026-11-21 integration-verifier 因簡報缺端點範例 BLOCKED;`/healthz` 被列入轉發比對 |
| 簡報有沒編號的需求 → BLOCKED | 第 0 步 + 測試(tests 情境 8,待實跑) | 2026-11-21 前端自訂 `RBAC-Q8-UI:`,verifier BLOCKED |
| Go 模組名取主 repo 目錄名,不是 worktree 目錄名 | 結構(`new-backend.sh` 從 git common dir 推專案名)+ 檢查(stack-go tests) | 2026-11-21 worktree 裡得到 `example.com/backend/backend`,主 agent 手動改名 |

## frontend-owner(2026-11-21 追加)

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 列表直接修改資料 / `並發` 元件情境 → 先讀 `stack-react/references/optimistic-updates.md`,5 條各有測試 | 成功標準 11a + 測試(tests 情境 9,待實跑)+ 文字(附失敗範例) | 2026-11-21 fortest 使用者列表:確認框重複送出、整列快照覆蓋、403 未重新取得權限、重新載入覆蓋新值,4 輪 review 每輪都有 |
| 簡報有沒編號的需求 → BLOCKED | 第 0 步 + 測試(tests 情境 10,待實跑) | 同 backend-owner |

## integration-verifier

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 標「經前端轉發:否」或不在 `/api/` 下的端點只驗直連 | 工作流程第 5 步 + 測試(tests 新情境,待實跑) | 2026-11-21 fortest 第 1 輪 `/healthz` 經前端 404 判 ISSUES |
| `並發` 情境依情境 Then 判定;簡報標準衝突時回報、以情境為準 | 工作流程第 5b 步 + 測試(同上) | 2026-11-21 協調者寫的並發判定兩次錯(A2/B2 觸發不了 409、`401 ≤ 5` 與 Q6 矛盾) |

## 協調者(多 agent 網站開發)

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 派工前逐條對照決策表:每條決策對應情境編號並出現在某 owner 簡報;判定標準引用情境 Then 或 owner 產出的表 | 文字(agent-forge `multi-agent.md` 派工第 8 條,附失敗範例);由 owner 的「沒編號 → BLOCKED」與 verifier 的「缺範例 → BLOCKED」兩道檢查兜底 | 2026-11-21 fortest:漏 Q8、追加需求沒編號、缺端點範例、並發標準寫錯 2 次 |

## gitlab-bot

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| GitLab API 回應先以 python 寬鬆解析(JSON 字串內可能有未跳脫控制字元)再交給 jq | 結構(`bot.sh` `api()`)+ 測試(tests 控制字元情境,含反向驗證) | 2026-11-21 MR !1 查詢時 jq `Invalid string: control characters` |
| merge 前觸發 `with_merge_status_recheck`,`unchecked` / `checking` 時輪詢最多 60 秒 | 結構(`bot.sh merge`)+ 測試(含反向驗證) | 2026-11-21 MR !1 第一次 merge 因 `unchecked` 被拒 |
| token 需要 `api` + `write_repository`;`identity` / `project` 檢查 scope,缺少時結束碼 3 | 結構(`bot.sh`)+ 測試 + SKILL.md | 2026-11-21 token 只有 `read_api`,開 MR 403 `insufficient_scope` |
| 查詢 `.gitlab-ci.yml` 只有 404 算「沒有 CI」,其他失敗拒絕合併 | 結構(`bot.sh ci_file_at`)+ 測試(MR !10 回 500,含反向驗證) | 2026-11-21 寫 gitlab-bot 測試時發現:401 / 500 會被當成沒有 CI 而自動合併 |

## 網站骨架(web-dev-kit / stack-go / stack-nextjs)

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 本機開發一律 Docker:骨架內建 Dockerfile 與執行時 `/api` 轉發;compose 只透過 `web-dev-kit/scripts/compose.sh`(必帶 `-p`,不刪 volume) | 結構(骨架、`compose.sh`)+ 測試(kit tests) | 使用者 2026-11-21 指示「本機開發都用 docker」;當次 backend-owner 規則只允許 `pg.sh`,compose build 只能由主 agent 跑 |
| integration-verifier 用 standalone `server.js` 啟動前端 | 結構(骨架 `start` 腳本)+ 工作流程第 3 步 | 2026-11-21 fortest 每輪驗證都出現 `"next start" does not work with "output: standalone"` 警告 |

## game-concept-artist

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 透明素材不能帶白色貼紙外框(提示詞不寫 sticker / sticker art) | 檢查(kit `sprite.mjs check` 外圈接近純白 > 30% 不通過,錯誤訊息附改法;`--full-bleed` 的 UI 不在檢查範圍,僅文字要求看圖)+ 測試(kit tests 白框 ×3、淺灰外圈、白色主體) | 2026-11-22 MahjongParty ticketpack-t5、bundlepack-t2~t6、VIP 卡多輪白框,靠人眼發現;已交付的 ticketpack-t5 現在會被擋下 |
| 底部留白依簡報(例如對齊既有素材的 8 px)用 `fit --foot`,不手動補像素 | 結構(kit `sprite.mjs fit --foot`)+ 測試(kit tests「--foot 8」) | 2026-11-22 MahjongParty 四輪都 fit 成 H-5 再補 5 列透明 |
| 非角色參考圖(現有素材、先前生成的圖)只能上傳簡報旗標「使用者授權上傳參考圖」列出的檔案;沒旗標時回報列出建議路徑 | 旗標 + 測試(tests 情境 9,2026-11-22 實跑:9A / 9B / 9C 的旗標行為都符合預期;9B 另發現重出覆寫交付檔,已改流程,見下一條)+ 限制條文 | 2026-11-22 MahjongParty ticketpack-t5、vippack-gold 兩次停下等主 agent 轉問 |
| 遊戲素材的交付檔(圖、背景、音訊)一律先產生在這次產出目錄的暫存區(`art/out/<本次產出目錄名>/stage/<group>/`),機器檢查與看圖都通過才只複製該項 `files` 到 `art/assets/`;沒通過的項目 assets.json 不動(不讓失敗的產出覆寫已交付的檔) | 僅文字(工作流程「遊戲素材」第 1 點,fit / cover / audio 的 `--out` 都改指向暫存);只發生 1 次;例外直接加入:會遺失已交付素材,且使用者 2026-11-22 指示「全部補完」 | 2026-11-22 情境 9B 實跑:失敗圖覆寫 shop.chest.png,agent 自行還原 |

## 協調者(agent-forge multi-agent)

| 規則 | 強制方式 | 來源(哪次錯誤) |
|---|---|---|
| 判斷能不能開 worktree,在每個 worker 的目標目錄跑 `git -C <目錄> rev-parse --show-toplevel`,不看 session 根目錄 | 僅文字(multi-agent.md 第 5 點,附失敗範例) | 2026-11-22 MahjongParty 開房券:三個 owner 共用 checkout,5 份回報 scope OUT 被汙染 |

## 待辦(暫緩)

只發生過 1 次,依 `improve.md`「同一類錯誤發生兩次才算教訓」暫緩。再發生一次就加進 agent。

| 項目 | 發生紀錄 | 再發生時的做法 |
|---|---|---|
| mac-widget-builder 交叉比對不能用 `python3` | 2026-11-16 主 agent 要求 python3 腳本比對,子 agent 改用 zsh + grep 達成,結果正確 | 再因為不能解析 JSON 而比對失敗時,加入 `python3 -I`(唯讀)或改用 `plutil -extract` |
| 主 agent 直接改 widget 時沒照 kit 規則(多加 .swift 檔、選單列 13 字) | 2026-11-16 主 agent 加 `Quota.swift`、`✻ 18% · 34.1M`,自行發現後合併並改成 11 字 | 再發生時,在 kit `SKILL.md` 開頭加「主 agent 修改也要跑 `tests` 的骨架 diff 與 menubar-length 檢查」 |
| 子 agent 執行第 4b 步 `open -n -W --stdout` 得到 `-10810` | 2026-11-16 加 Sessions 時(同一天稍早的重測可以跑);主 agent 在自己的 shell 重跑 4b 通過 | 再發生時,在 4b 加「`-10810` 是執行環境限制:回報指令、狀態不因此判 ISSUES,由主 agent 代跑」 |
| 測試時反覆跑 `--once` / snapshot,把有限流的外部 API 打到 429 | 2026-11-16 加 Sessions 時,額度 API 被打到 429(Retry-After 216 秒);主 agent 補上 429 退避與沿用舊值 | 再發生時,在工作流程加「外部 API 有限流時,驗證期間 `--once` / snapshot 合計不超過 N 次」,並要求 Provider 處理 429 |
| PDF 附件要連圖表頁一起讀(Read `pages`) | 2026-11-15 台積電法說會簡報,當時沒裝 poppler,圖表頁讀不到(環境問題,已由使用者安裝 poppler 解決) | 子 agent 漏讀圖表頁時,加進工作流程第 6 步 |
| short-video-maker 字幕蓋住內容(非置頂鏡頭) | 2026-11-18 craft-anything 第二版字幕蓋住 Add a brain 卡片。置頂鏡頭已由結構避免;直式鏡頭(網頁錄影、原聲模式)仍可能發生 | 再發生時,verify.sh 對直式鏡頭比對字幕框區域在有 / 無字幕時的畫面差異,或 record-web 預留字幕區 |
| short-video-maker 沙盒錄影(Docker + Xvfb,桌面 App / 不信任的 repo) | 2026-11-18 主 agent 手動完成:先建只含系統工具的映像檔(`--cap-drop ALL` 下 apt 會失敗),再以 uid 1000、`--cap-drop ALL`、`no-new-privileges`、不掛載、只開 127.0.0.1 埠執行;用官方預編版本不編譯;egui App 收不到 `xdotool type`、檔案對話框打不開 → 改用點擊與啟動參數帶路徑;錄完刪容器與映像檔 | 再有使用者要求時,把流程做成 kit 腳本(`sandbox-record.sh`)與新模式,加測試 |
| short-video-maker 旁白事實簡化失真 | 2026-11-18 craft-anything 第一版把 MIT / Apache-2.0 雙授權念成「MIT 授權」,沒提 early alpha(agent 自己列在已知限制) | 再發生時,在 repo 模式第 2 步加「授權、版本狀態照 README / LICENSE 原文,不簡化」並在 script.md 附來源 |
| integration-verifier:非 `/api/` 端點自動只驗直連(不靠簡報標示) | 2026-11-21 `/healthz`(1 次,且是協調者簡報錯誤;已由端點驗證表的「經前端轉發」欄涵蓋) | 再發生時,verifier 第 5 步改為讀前端 `proxy.ts` 的 matcher 自動判定 |
| 協調者沒先 build 就跑 `tsc`(`LayoutProps` 找不到) | 2026-11-21 主 agent 在新 checkout 直接 `tsc --noEmit`;frontend-owner 已有「build 之後才跑 tsc」規則 | 再發生時,骨架 `typecheck` 腳本改為 `next typegen && tsc --noEmit` |
| game-concept-artist 錢幣上出現 $ / 字形 | 2026-11-22 MahjongParty ticketpack-t5 三次都有 $(同一輪;之後加負向 dollar sign / text 就沒再出現) | 再發生時,STYLE.md 負向基底固定加 dollar sign, currency symbol, text, kanji,或 check 加 OCR 類檢查 |
| game-frontend-owner 在既有專案 `check-assets` / `check-early` 回 layout absent、沒有 cycleLeak 工具 | 2026-11-22 MahjongParty rt-lobby,改用專案自己的同等測試與手寫 soak | 再發生時,stack-pixi 檢查腳本支援既有專案的 layout 設定或提供 soak 工具 |
| frontend-owner 說明只寫 Next.js,實際用在 Vite + React 後台 | 2026-11-22 MahjongParty rt-admin,照現有慣例完成,E2E 只能 mock 模式 | 再發生時,description 改「React(Next.js 或 Vite)」並在工作流程分支 |

## review 待查(還沒實際發生過)

code review 找到、但還沒有真的出事的潛在問題。**實際發生第一次時,移到上面的「待辦」**(那時才算第 1 次),不要把這裡的紀錄當成第 1 次。

| 項目 | 來源 | 實際發生時的做法 |
|---|---|---|
| game-art-kit `whiteHalo` 距離:格子邊緣的不透明像素(距離 1)和透明像素(距離 0)放同一個佇列依列序處理,邊緣附近少數像素距離可能多 1 | 2026-11-22 xhe PR #32 第 5 輪 review | 佇列先放所有距離 0 再放距離 1(兩段 BFS) |
| `--foot` 大於 3 時 anchor [0.5, 1] 會讓物件浮起 foot / density 顯示 px | 同上 | assets.json 記 foot 偏移或依 foot 算 anchor y |
| 有 `character` 又列在參考圖旗標時要兩張參考,規格只寫一張 | 同上 | 定好優先序(角色 ref 優先)或加 `qwen-edit-2ref` 骨架說明 |
| 白色或很淺的非滿版 `ui`(白色按鈕、白框風角色)會被白框檢查擋下 | 同上 | 文件寫明這類素材加 `--allow-white-edge`,或 `ui` 類略過白框檢查 |
| 外圈不到 20 px 的小圖不做白框檢查,但輸出沒有提示 | 同上 | `check` 在 halo_edge < 20 時輸出提示,請 agent 看圖 |
