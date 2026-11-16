# mac-widget-builder 使用紀錄

| 日期 | 任務 | 結果 | 證據 | 發現的問題 |
|---|---|---|---|---|
| 2026-11-16 | 新建 ClaudeTokenWidget(本機 Claude Code token 用量,both) | PASS | `--once` 與 zsh+grep 獨立解析今日 338 則、31,357,414 tokens 完全一致;snapshot 已檢視 | 只在終端機驗證,GUI 啟動時讀不到外接磁碟上的 widget.json(使用者回報「無資料」);拖曳無效(使用者回報)。主 agent 修 kit 解決 |
| 2026-11-16 | 修改 ClaudeTokenWidget,加訂閱額度(鑰匙圈 OAuth) | BLOCKED | 無對應鑰匙圈旗標、`security` 不在清單 | 使用者已同意但規則無法表達;主 agent 自行完成(額度與 curl 一致、輸出無 token)。已新增鑰匙圈旗標 |
| 2026-11-16 | 重測(暫存副本):有鑰匙圈旗標,加方案名稱標籤 | ISSUES | 接受旗標、第 4b 步通過、`grep -c sk-ant` = 0、骨架 diff 無差異;主 agent 補做 `security … \| plutil -extract subscriptionType` → `max`,與 gui-once.json 一致 | 子 agent 誤以為 `security` 不在清單而沒交叉比對;已把該條改成明確允許並附失敗範例 |
| 2026-11-16 | 修改 ClaudeTokenWidget,加 Sessions 區塊(~/.claude/sessions,10 秒更新) | ISSUES | sessions 名稱 / 狀態 / 排序與 plutil + `kill -0` 一致;死 pid 與 pid 重用用測試檔驗證排除;`--once` 0.34 秒 | 4b 在子 agent 環境 `-10810`(主 agent 重跑通過);測試把額度 API 打到 429;用了清單外的 `sed -i`、`cd`、`time`、`wc` |
