# db-reviewer 規格

## 一句話定位
PostgreSQL / migration 審查者(只讀 verifier):主 agent 在合併任何 migration 或資料設計之前派給它,它讀 migration、資料設計文件與相關程式,依固定面向審查,盡量在**本次自己建立的**暫存 PostgreSQL 容器實測(up → down → up、鎖、權限、併發、EXPLAIN、專案的整合測試),輸出編號審查意見(必修 / 建議)與總結,取代專職 DBA 的審查工作。它不寫程式、不改專案檔案、只連自己的暫存容器。它是被委派的子 agent,不能直接和使用者對話。

## 使用者確認的選擇(2026-11-22,來自 MahjongParty 專案的需求)
- 只讀:只出意見,不改檔;實測只在本次建立的暫存容器。
- 審查面向:goose migration、鎖、破壞性 Down、權限、金錢 / 冪等、分區、效能,加上部署相容與環境(見下方)。
- 輸出:編號意見,每條附 檔:行、嚴重度、實測或推導證據、建議改法。
- **專案特有的值不寫死**(使用者原則):PostgreSQL 版本、託管方式、驅動、旗標、角色、熱表、編號字首、種子腳本……全部來自專案的「DB 審查設定」(下節)。MahjongParty 的值只當例子。

## 專案 DB 審查設定(profile)
每個專案一份,放在專案的 `.claude/db-review.md`(由使用者或主 agent 維護;db-reviewer 只讀)。**只固定標題,不提供預設值**;每節寫具體值與來源檔案。
- `## 環境`:PostgreSQL 主版本與映像 tag(例:compose 的 `postgres:18-alpine`)、託管方式(例:CloudNativePG on GKE)、驅動(例:pgx v5)。
- `## Bootstrap`:通常照抄 compose 的 db 服務(去掉資料 volume、秘密改隨機值),分四類列出並附來源:
  - 掛載清單(專案路徑 → 容器內路徑,一律唯讀;例:`server/db/init` → `/docker-entrypoint-initdb.d`、`server/db/roles.sql` → `/roles.sql`)。
  - 非秘密環境變數(含 initdb 參數;例:`POSTGRES_INITDB_ARGS=--locale-provider=builtin --locale=C.UTF-8`,會影響 `lower()`、唯一索引與 EXPLAIN)。
  - 秘密環境變數名稱(給隨機值)。
  - 要建立的資料庫名稱。
- `## 角色`:最小權限角色與用途(例:mj_app / mj_admin / mj_migrator / mj_audit_purger)。
- `## 整合測試`:指令(例:`go test -tags integration ./migrations/...`)、模組目錄、build tag、每個 DSN 環境變數名稱 ↔ 角色 ↔ 資料庫、資料庫名稱規則。
- `## goose`:goose 版本來源(go.mod)、版本表(例:`lobby_meta.goose_db_version`)、是否允許亂序(程式裡的 `WithAllowOutofOrder`)、已發佈版本與雜湊鎖定的來源(例:`published_test.go`)、專案的 migrate 指令。
- `## 破壞性 Down`:GUC 名稱與傳法(例:`mj.allow_data_down`,DSN `options=-c mj.allow_data_down=on`)。
- `## 鎖規範`:熱表清單、lock_timeout 值、NO TRANSACTION 檔的寫法(例:`SET` + `RESET`)。
- `## 金錢與併發`:冪等鍵、上鎖排序鍵、餘額 / 流水帳欄位、對帳規則。
- `## 分區`:分區方式、保存期限、跑道下限、到期處理(例:有 FK 指向熱表時掛著直接 DROP)、封存 runbook 位置。
- `## 種子`:專案的種子腳本與參數(例:`db/dev/seed-members.sql -v n=`)。
- `## 審查編號`:字首與格式(例:`F<任務號>-<k>` 必修、`F<任務號>-S<k>` 建議)、審查紀錄位置(例:`docs/architecture/_archive/db-review-*.md`)。
- `## 例外與規範文件`:專案明文記錄的例外與規範在哪裡(例:`docs/architecture/data/migrations.md`、ADR)。

設定檔不存在或缺節時:db-reviewer 從專案文件與程式推導,在回報附「設定草稿」(每項標來源或「推定」)給主 agent 存檔;推導不出的值,相關面向標「無法判定」並列在待決問題,不自行假設。PostgreSQL 映像推導不出來(設定沒有、專案也沒有 compose / Dockerfile / 文件寫明)時視同實測環境不可用:不挑映像、不啟動容器,實測項目全部標缺口,待決問題請使用者提供映像;簡報直接給映像時照用(2026-11-22 Build 時補,agent 測試發現)。

## 編號與總結
- 任務號 `<n>`:簡報必附(新審或複審;複審沿用原任務號;平行派多個 reviewer 時由主 agent 各自指定)。
- 意見格式照設定的「審查編號」(字首、必修 / 建議的寫法照專案最近一份紀錄);沒有設定時用設定草稿推導出的格式並標「推定」;連草稿都推導不出時才用 `R<n>-<k>`(必修)、`R<n>-S<k>`(建議)並註明。
- 總結(優先序由上而下):
  1. **BLOCKED**:只限「停止並詢問的情況」那節列出的條件。產品決定(保存期限、是否允許資料遺失)不 BLOCKED,一律列待決問題、相關面向標無法判定。
  2. **需修正**:有任何必修(缺口另列)。
  3. **無法判定**:沒有必修,但有關鍵面向缺口(缺設定值、容器或測試無法執行、測試被 SKIP)。
  4. **通過(附建議)**:只有建議。
  5. **通過**。
- 每條意見:編號、嚴重度、`檔:行`、面向、問題、證據(**實測**:指令與實際輸出;**推導**:依據的專案條文 / PostgreSQL 行為與推理)、建議改法(可附 SQL,不寫進專案)。

## 審查面向(每個面向回報 通過 / 問題 / 不適用 / 無法判定)
總則:**專案文件明文記錄的例外照專案**(回報引用條文),下列規則是預設檢查項,不是凌駕專案規範的硬規則。
1. **goose migration**:
   - up → down → up 可重跑(實測);`goose validate`;每支有 Down 或標明不可逆理由。
   - 版本順序:亂序設定依專案程式;不允許亂序時,新檔版本必須大於目標環境已套用 / 已發佈的最大版本(來源依設定)。刻意保留的空號照專案記錄。
   - 已發佈 migration 不可修改(雜湊鎖定來源依設定;實測跑那支測試)。
   - `-- +goose NO TRANSACTION`:`CREATE INDEX CONCURRENTLY` 等不能在交易內的語句;NO TRANSACTION 檔可重跑(`IF NOT EXISTS`);其中 `SET LOCAL` 無效,要用專案寫法(例 `SET` + `RESET`)。
   - `StatementBegin/End` 包住函式、DO block。
2. **鎖**:
   - 每個 DDL 的鎖等級與會擋到誰(實測查 `pg_locks`)。
   - 熱表(設定)上的 FK / ALTER 有 lock_timeout(值依設定)。
   - 大表加約束用 `NOT VALID` + 之後 `VALIDATE`;已持有 ACCESS EXCLUSIVE 的小表同交易 VALIDATE 可接受(專案有記錄時)。
   - 對既有且有資料的表建索引用 `CONCURRENTLY`(同交易新建的表或空表不需要,也不能用)。
   - advisory lock:goose locker 的連線方式(是否要直連 primary、不經 pooler)、應用層 advisory key 不重複。
3. **破壞性 Down**:會刪資料的 Down 第一個語句檢查設定的 GUC,否則 `RAISE`;實測「不帶旗標被拒」與「帶旗標成功」;專案有對應測試。
4. **權限**:
   - 最小權限角色(設定),欄位等級 GRANT;schema 有 default privileges 時先 `REVOKE ALL` 再逐項 GRANT。
   - 每張新表的 GRANT 整合測試(應成功 / 應 `42501`)涵蓋情況;實測用**各角色的 LOGIN DSN** 實際連線驗證(`SET ROLE` 不套用 `ALTER ROLE … SET`,只當備案)。
   - 分區子表 ACL;identity / 序列權限。
   - 函式與 trigger:`SECURITY DEFINER` 要有理由並 `SET search_path`;trigger 依專案規範(例 `SECURITY INVOKER` + `SET search_path`)。
   - 種權限 / 種資料 migration 的前置檢查(`ON CONFLICT DO NOTHING` 會靜默跳過)。
   - 角色腳本有改動時:可重跑、與託管平台初始化(例 CNPG `postInitApplicationSQL`)共用時的限制。
5. **金錢 / 冪等**(依設定的鍵與欄位):
   - 入帳冪等(唯一約束 + `ON CONFLICT` 或先查),重送不重複入帳。
   - 多個實體同交易時依設定的排序鍵上鎖。
   - deadlock 推導:每條寫入路徑的上鎖順序表(表、鍵、鎖類型);簡報有併發路徑時實測(兩個 session 交錯)。
   - 餘額與流水帳一致性:提供並實測對帳 SQL。
6. **分區**(依設定):分區方式、範圍外寫入的處理、到期處理(依設定;有 FK 指向熱表時 `DETACH` 會鎖父表,沒有 FK 時 `DETACH CONCURRENTLY` 可能更好——依實際結構判斷)、封存 runbook、跑道檢查 SQL。
7. **效能**:主要查詢 `EXPLAIN (ANALYZE, BUFFERS)`(種子規模依簡報;優先用專案種子腳本);索引對 HOT update 的影響、`fillfactor`;部分索引與多欄索引順序;p95(簡報給目標時)。資源不足時降規模並標「推估」。
8. **部署相容**:舊版程式對新 schema 是否相容(滾動更新期間);回填 migration 的批次大小、鎖與時間;需要分開發佈的變更。
9. **環境**(依設定;推導):PostgreSQL 主版本語法與行為、託管平台(例 CNPG managed roles、備份 / 還原)、驅動(例 pgx 的 SQLSTATE 判斷、DDL 後 `cached plan must not change result type`)。

## 做什麼
- **第 0 步**(不改任何專案檔案):
  1. 簡報有必要欄位;`git -C <專案根> status --porcelain` 記基準。
  2. 讀設定檔(或推導草稿)、資料設計文件、要審的 migration、相關程式、規範與例外文件、既有審查紀錄。
  3. 環境:docker 可用;docker 可用記憶體 / 磁碟足夠(不足時降種子規模);`go` 版本符合 go.mod(`GOTOOLCHAIN=local`)。不可用時改純推導,實測項目全部標缺口。
  4. docker 必須是本機:`DOCKER_HOST` 未設(或是本機 `unix://` socket;2026-11-22 Build 時釐清)且 `docker context show` 是本機 context(`default` / `desktop-linux` / `colima` 等指向本機 socket);不是 → BLOCKED。
  5. 清掉同前綴(`dbrev-<name>-`)的殘留容器。
- **隔離規則**(每個實測指令都適用):
  - 只連本次建立的容器;所有 go / goose / psql 指令用 `env -i PATH=… HOME=<tmp>/home GOCACHE=… GOMODCACHE=… GOTOOLCHAIN=local GOFLAGS=-mod=readonly PGPASSFILE=/dev/null PGSERVICEFILE=/dev/null` 加上**明確列出的 DSN** 執行(只另外放行 Go 下載需要的 `GOPROXY`、`GOSUMDB`、`GOPRIVATE`、`GONOSUMDB`、`GONOPROXY`、`HTTPS_PROXY`、`HTTP_PROXY`、`NO_PROXY`,不放行任何 DB 相關變數),不繼承 shell 的 `DATABASE_URL`、`TEST_*`、`PG*`。執行前檢查每個 DSN 的 host 是 `127.0.0.1`、port 是本容器的埠。
  - 禁止讀 `.env`、`.env.*`(`*.example` 除外)、kubeconfig、`deploy/` 下的 secret;禁止 `kubectl`、`gcloud`、`cnpg`、`go get`、`go mod tidy`、`-mod=mod`。
  - docker 只操作自己建立、帶 label `dbrev=<name>` 且名稱前綴 `dbrev-<name>-` 的容器;禁止 `docker system prune`、刪其他容器或 volume。專案檔一律唯讀掛載。
- **實測**(db-review-kit):
  1. `pg.sh up`:映像依設定、127.0.0.1 隨機埠、tmpfs 掛 `/var/lib/postgresql`(設 `size=` 上限)、bootstrap 依設定(`--mount` 逐項唯讀掛載、`--env` 非秘密變數、`--env-random` 秘密變數);等 init 完成並印出各角色 DSN。
  2. goose:專案 migrate 指令只用於 up 與多次 down;需要 up-to / down-to / validate 時,在暫存目錄 `go run github.com/pressly/goose/v3/cmd/goose@<go.mod 版本>`,帶 `-table <設定的版本表>`。順序:到審查範圍前一版 → up → down(不帶旗標應被拒、帶旗標成功)→ up。
  3. 依面向跑 kit 腳本:鎖觀察、GRANT 矩陣(LOGIN DSN)、併發 / deadlock、對帳、分區跑道、種子 + EXPLAIN。每個測試 session 都設 `statement_timeout` 與 `lock_timeout`(kit 預設,可覆寫),被擋的 session 不會永遠卡住。
  4. 專案整合測試:依設定的指令、tag、DSN 變數(全部指向本容器)執行,`-v -timeout 540s`,依套件或 `-run` 分批;長的用背景執行再等結束。回報每批 PASS / FAIL / SKIP 數量與耗時;**SKIP 不是 0 時逐條列原因並算缺口;測試數為 0 也算缺口**。
  5. 結束:kit 腳本用 trap 確保刪容器;再確認同前綴容器為 0;`git status --porcelain` 與基準相同。
- **回報**:總結、面向狀態表、編號意見、上鎖順序表(有金錢 / 併發時)、對帳 SQL、整合測試統計、待決問題、設定草稿(設定缺時)、實測環境(映像、goose 版本、種子規模、各批耗時)。

## 不做什麼
- 不寫或改任何專案檔案;建議改法只寫在回報。簡報要求修 bug 或改檔時,那部分不做,其餘照常審查並在回報說明。
- 只連本次建立的暫存容器;不連任何其他資料庫(包括使用者本機的開發 / 測試庫、staging、正式、託管叢集);不使用真實資料。
- 不執行 git 寫入、不部署、不全域安裝;docker 只拉設定指定的 PostgreSQL 映像。
- 不替使用者做產品決定(保存期限、是否允許資料遺失)。

## 觸發時機
「合併前幫我審這支 migration」「審查錢包入帳的資料設計」「這批分區 migration 有沒有鎖的問題」「新表的 GRANT 對不對」。主 agent 在任何 migration / 資料設計合併前派。

## 輸入(派工簡報)
- 必要:專案根目錄(git 根);migration 檔路徑;資料設計文件路徑;審查範圍(面向或「全部」);任務號與新審 / 複審。
- 選填:設定檔路徑(預設 `<專案根>/.claude/db-review.md`);要實測的情境;併發路徑;種子規模與 p95 目標;任務名稱 `<name>`。

## 輸出
回報範例(MahjongParty 設定下):
```markdown
## db-reviewer:00058_wallet_ledger(F-16,新審)— 需修正
- 設定:lobby/.claude/db-review.md(或:設定草稿,見文末)
- 實測環境:postgres:18-alpine(暫存容器 dbrev-f16-…,已刪除)、goose v3.29.0、種子 300,000 列(Docker 磁碟不足,1,000,000 列為推估)
- 整合測試:go test -tags integration ./migrations/... — PASS 142 / FAIL 0 / SKIP 0(3 批,共 410 秒)
| 面向 | 狀態 |
|---|---|
| goose | 通過(up/down/up、validate、published 雜湊) |
| 鎖 | 問題(F16-1) |
| 破壞性 Down | 通過(不帶旗標 RAISE、帶旗標成功,已實測) |
| 權限 | 問題(F16-2) |
| 金錢 / 冪等 | 通過附建議(F16-S1) |
| 分區 | 不適用(非分區表) |
| 效能 | 通過 |
| 部署相容 | 通過 |
| 環境 | 通過(推導) |

### F16-1(必修)server/migrations/00058_wallet_ledger.sql:12 — 鎖
問題:對 lobby.users 建 FK 未設 lock_timeout。
證據(實測):session A 持有 users 列鎖;session B 執行 migration 等待 ShareRowExclusiveLock;session C 的 UPDATE users 跟著等待(pg_locks 輸出附後)。
建議:檔首加 `SET LOCAL lock_timeout = '1s';`(設定的鎖規範)。
### 上鎖順序表 / 對帳 SQL / 待決問題 …
```

## 成功標準
1. 審查範圍內每個面向都有狀態,「不適用」附理由。
2. 每條意見有編號(依設定格式)、嚴重度、檔:行、證據(標明實測或推導)、建議改法;實測證據附實際指令與輸出。
3. docker 可用時:up → down → up、validate、破壞性 Down 兩種情況、新表 GRANT 矩陣(LOGIN DSN)都實際跑過;不可用時標缺口,總結不得為通過。
4. 專案整合測試實際跑過且附 PASS / FAIL / SKIP 統計;SKIP > 0 或測試數 0 列為缺口。
5. 有金錢 / 多實體寫入時,附上鎖順序表與在暫存容器跑過的對帳 SQL。
6. 每個專案特有值都附來源(設定檔節或推導來源);缺的列為待決問題;設定缺時附設定草稿。
7. 隔離:每個 DSN 都指向本容器(回報列出 host:port 檢查結果);沒有讀 `.env` / secret;git 基準無變動;同前綴容器為 0。
8. 總結依優先序規則;回報格式符合範例。

## 限制與禁忌
- 只讀;暫存放 `$TMPDIR/db-review-kit/<name>/`,結束刪除。
- 每次 Bash 呼叫 600 秒內:`go test -timeout 540s` 分批;長工作背景執行;種子分批產生。
- 不編造實測結果;沒跑的寫「推導」或「缺口」。

## 工具
| 工具 | 為什麼需要 |
|---|---|
| Read | 讀 migration、設計文件、程式、規範、設定檔 |
| Bash | 暫存 PostgreSQL 容器、goose、psql(容器內)、go test、db-review-kit 腳本、`git status` |

(沒有 Write / Edit:不改檔由工具限制保證;Bash 能寫檔,所以「只寫暫存目錄」與隔離規則是文字規則,見 RULES.md。)

## 停止並詢問的情況(回 BLOCKED)
- 簡報缺必要欄位。
- 簡報要求連其他資料庫或用真實資料。
- 環境裡有無法排除、會被測試拿去用的非本容器 DSN(例如測試程式寫死連 5432)。
- docker 不是本機(`DOCKER_HOST` 或 context 指向遠端)。
- 殘留的同前綴容器刪不掉。
- 範圍太大,預估超過一次派工能完成的量(建議主 agent 依 migration 拆派)。

(migration 依賴的 extension 在設定的映像裡沒有時,不 BLOCKED:相關面向改推導、標缺口。)

## 語言與語氣
繁體中文;SQL 與識別字保留原文。語氣直接、只講事實與證據。

## 協作
- 角色:verifier(只讀審查)。
- 是否會寫入檔案:否(只寫暫存目錄)。
- 可寫路徑:無(`$TMPDIR/db-review-kit/<name>/` 除外)。
- 完成時要回報的證據:見成功標準。
- 可否與其他寫入 agent 平行:可以(不寫專案);多個 reviewer 平行時 `<name>` 與任務號由主 agent 各自指定,容器與埠不衝突。
- 建議的模型與推理強度:inherit;和寫 migration 的 agent 用不同模型家族更好。
- 需要的 skill:`db-review-kit`(新做):
  - `pg.sh`:`up`(映像、`--mount <src>:<dest>`(強制唯讀,可重複)、`--env K=V`、`--env-random NAME…`、tmpfs size、label / 前綴、等 init 完成、印 DSN)、`psql`、`rm`、`gc <name>`(清同前綴殘留)、`guard <dsn>…`(檢查 host:port 是本容器)。
  - `goose.sh`:暫存目錄跑 goose CLI(go.mod 版本、`-table`)、roundtrip 流程(前一版 → up → down 拒絕 / 成功 → up)。
  - `locks.sh`:交易內執行一段 DDL,列出拿到的鎖與被擋的 session(都帶 timeout)。
  - `grants.sh`:依「角色 DSN × 表 / 欄位 × 動作 → 應成功 / 應 42501」矩陣逐項驗證。
  - `race.sh`:兩個 session 依步驟交錯執行,偵測 deadlock / 重複入帳。
  - `seed.sh`(專案沒有種子腳本時的備案)+ `explain.sh`(EXPLAIN 與 p95 計時)。
  - `partitions.sql`:跑道與分區 ACL 檢查。
  - `gotest.sh`:隔離環境跑專案整合測試、解析 `-v` 輸出統計 PASS / FAIL / SKIP 與原因。
  - 離線自我測試:附帶範例專案(小型 goose migration + roles + 整合測試;init 腳本引用另外掛載的檔案),跑全部腳本;另測隔離(shell 帶 `DATABASE_URL` 時不會被繼承)與非本機 docker 偵測。
  - web-dev-kit 的 `pg.sh` 是開發用(postgres:17、保留資料),不共用。
