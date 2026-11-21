# 並發與原子性(需要時才讀)

有 `並發` 類型的驗收情境,或端點涉及「先檢查再寫入」、計數 / 鎖定、不變量(例如至少一位 admin)、會累積的資料表時,實作前先讀完這份。

以下做法都來自 2026-11-21 fortest 登入 + RBAC 的 4 輪 code review,每一條都是真的出過錯、反向驗證過的。

## 1. 檢查和寫入要在同一個鎖裡

錯誤寫法:先讀狀態(是否鎖定、權限、admin 數),跑一段慢的事(bcrypt),再在另一個交易寫入。中間別的請求也通過了同樣的檢查。

- **權限**:`authorized` 在交易外檢查過還不夠。寫入交易內要再讀一次操作者(PostgreSQL `SELECT … FOR UPDATE`),已不具權限 → 403、目標不變。
- **不變量**(例如啟用中 admin ≥ 1):交易一開始依固定順序鎖住相關列(`SELECT id FROM users WHERE role='admin' AND NOT disabled ORDER BY id FOR UPDATE`),算完「變更後還剩幾個」再寫。所有會動這些列的寫入都走同一種鎖定順序,才不會死結。
- **錯誤碼順序要和情境一致**:同一份鎖住的資料可能同時違反兩條規則(例如並發互相降級時,後到者既不再是 admin,又會讓 admin 變 0)。先檢查哪一條決定回哪個碼,要對照情境的 Then 決定並寫註解;不要憑直覺排。

## 2. 次數限制:依 key 序列化,不要「預約額度」

錯誤寫法 A:讀 `failed_count < 5` → bcrypt → 寫入失敗。50 個並發請求全部通過檢查。
錯誤寫法 B(第 2 輪的「修正」,造成回歸):比對前先預約一次額度,額度滿就 423。並發的**正確**密碼也被擋成 423,但帳號根本沒鎖。

正確寫法:同一個 key(email)的整段流程依序執行。
- 程序內:keyed mutex(`map[key]*entry` + 參考計數,用完刪除,避免 map 無限成長);等鎖時尊重 request ctx。
- 多程序(PostgreSQL):在同一個交易內 `SELECT pg_advisory_xact_lock(hashtextextended('login:' || $1, 0))`,commit 才放開。鎖內:讀鎖定狀態 → 鎖定中 423 → bcrypt → 寫失敗 / 清除。
- SQLite 只用程序內 mutex,**不要**在 bcrypt 期間持有寫入交易(`_txlock=immediate` 會擋住全部寫入)。
- 限制同時進行的登入交易數(例如 16),並在 README 註明連線池上限必須大於它。

## 3. 清理會累積的資料,而且移出主要交易

- 每次失敗都新增的列(登入失敗紀錄)、每次登入都新增的列(session)都要有清理;未登入就能觸發的寫入一定要有上限或清理。
- 清理**不要**放在登入交易裡:它和「停用使用者刪 session」用不同索引、不同順序鎖同一批列,PostgreSQL 會 40P01 死結。
- 清理放在 commit 之後另一個 statement,失敗只記 log;PostgreSQL 用 `DELETE … WHERE pk IN (SELECT pk … FOR UPDATE SKIP LOCKED)`,讓清理永遠不等鎖。光是移出交易、不加 SKIP LOCKED,反向驗證一樣會死結。

## 4. context 要有上限

- 拿到鎖之後要 `context.WithTimeout(context.WithoutCancel(ctx), 10*time.Second)`:不因用戶端斷線中途放棄已比對的失敗紀錄,但也不會無限卡住。逾時一定要釋放 slot、mutex,交易 rollback。
- 等鎖時用戶端斷線(`context.Canceled`)不是伺服器錯誤:不要寫 500 與 ERROR log。

## 5. 整數參數與讀取一致性

- 頁碼等整數只有下限會溢位:`(page-1)*size` 變負數,PostgreSQL 回 500、SQLite 回第 1 頁。契約加 `maximum`,handler 再做防溢位檢查。
- 列表的 `total` 和 `items` 放同一個讀取交易(PostgreSQL REPEATABLE READ),或用 `COUNT(*) OVER()`。

## 6. 測試:用 Hook 做出交錯,並做反向驗證

- 在 `httpx.Deps` 放只給測試用的 `Hook func(name string)`(正式環境 nil),handler 在關鍵點呼叫(比對密碼前、寫入交易前、建立 session 前)。測試用它把請求卡住、讓另一個請求先 commit,再放行。這樣的測試是確定性的;只靠「同時送很多個」是機率性的,不能當唯一證據。
- **每個並發測試都要反向驗證**:在暫存複本拿掉修正(鎖、FOR UPDATE、SKIP LOCKED、重驗),確認測試會失敗,回報附失敗訊息。沒做反向驗證的並發測試不算數。
- **擋與放都要測**:有「該被擋」的並發測試(50 個錯誤密碼只比對 5 次),就一定要有「不該被擋」的(10 個並發正確登入全部 200)。只測擋的,修法就可能把正確請求一起擋掉。
- PostgreSQL 才會出現的問題(死結、鎖等待)用 `TEST_DATABASE_URL` 跑;必要時 `SET enable_seqscan=off` 強制走索引,模擬大表的鎖定順序。
- 實際伺服器上再用 `node <kit>/scripts/concurrency.mjs` 對受影響的端點跑一次,回報狀態碼分佈。
