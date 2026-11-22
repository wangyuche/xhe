---
name: db-review-kit
description: PostgreSQL / goose migration 審查用的固定腳本(只連本次建立的暫存容器):pg.sh(暫存 PostgreSQL 容器:映像依專案、127.0.0.1 隨機埠、tmpfs 有大小上限、label / 名稱前綴、唯讀掛載 bootstrap、隨機秘密、等 init 完成印各角色 DSN、DSN 守門、拒絕非本機 docker、gc 殘留)、goose.sh(go.mod 版本的 goose CLI、-table、up → down 拒絕 / 成功 → up roundtrip)、locks.sh(DDL 拿到的鎖、hold / probe 被擋情境)、grants.sh(角色 LOGIN DSN × 物件 × 動作 → ok / 42501 矩陣)、race.sh(兩個 session 交錯:deadlock、重複入帳、對帳 CHECK)、seed.sh、explain.sh(EXPLAIN ANALYZE BUFFERS 與 p95)、partitions.sql(跑道、子表 ACL、FK)、gotest.sh(env -i 隔離跑專案整合測試,統計 PASS / FAIL / SKIP 與 SKIP 原因)。db-reviewer 審查 migration 時使用;任何要在拋棄式 PostgreSQL 實測 migration、鎖、權限、併發的情境也可用。
---

# db-review-kit

`<kit>` = 這個 skill 的目錄。暫存檔放 `${DB_REVIEW_KIT_TMP:-$TMPDIR/db-review-kit}/<name>/`(狀態檔、goose 執行檔、go test log),`pg.sh rm <name> --purge` 刪除。

`<name>`:小寫英文、數字、連字號(例 `f16`、`dbrev-lobby-00072`)。容器名 `dbrev-<name>-<亂碼>`,label `dbrev=<name>`;一個 `<name>` 同時只有一個容器。平行審查時主 agent 給不同的 `<name>`。

結束碼(全部腳本):0 成功、1 失敗、2 用法錯誤、3 Docker 沒在執行、4 隔離拒絕(非本機 docker、DSN 不是本容器、唯讀掛載被改成可寫)、5 測試缺口(gotest:有 SKIP 或測試數 0)。

## 腳本

```bash
# 環境檢查:docker 是否本機(DOCKER_HOST 只接受 unix://;context 端點要是 unix:// / npipe://)、Docker 記憶體 / CPU、暫存磁碟、go 版本
bash <kit>/scripts/pg.sh check

# 暫存 PostgreSQL(依專案設定的 Bootstrap 照抄 compose 的 db 服務:去掉資料 volume、秘密改隨機)
bash <kit>/scripts/pg.sh up <name> --image <設定的映像> \
  [--mount <專案路徑>:<容器路徑>]...      # 一律唯讀(帶 :rw 結束碼 4);來源要存在
  [--env K=V]...                          # 非秘密(例 POSTGRES_INITDB_ARGS=…)
  [--env-random NAME ...]                 # 秘密:每個給 32 位隨機 hex
  [--role <登入角色>=<密碼變數>]...        # 印出這個角色的 DSN(密碼取自 --env-random / --env)
  [--db <資料庫>]...                       # 不存在就建立;每個角色 × 每個資料庫印一行 DSN
  [--superuser postgres] [--tmpfs-size 1g] [--timeout 120]
# → container=… port=… image=… tmpfs=… ready_seconds=…
#   dsn role=<角色> db=<庫> url=postgres://…@127.0.0.1:<埠>/<庫>?sslmode=disable   (superuser 永遠有,密碼隨機)
#   init 腳本失敗或容器提早結束:印最後 40 行 log、刪容器、結束碼 1。同名容器已存在:結束碼 1(先 gc)
bash <kit>/scripts/pg.sh dsn <name> <角色> <庫> [--options '-c mj.allow_data_down=on']
bash <kit>/scripts/pg.sh psql <name> <dsn> [psql 參數]      # SQL 從 stdin(容器內 psql,看不到主機檔案,用 < 檔案)
bash <kit>/scripts/pg.sh guard <name> <dsn>...               # 逐一印 guard ok / FAIL;有 FAIL 結束碼 4
bash <kit>/scripts/pg.sh rm <name> [--purge]                 # 刪容器(--purge 連暫存目錄)
bash <kit>/scripts/pg.sh gc <name>                           # 第 0 步:清 label dbrev=<name> 且前綴 dbrev-<name>- 的殘留 → gc … remaining=0

# goose(版本取自 go.mod;只複製 *.sql 到暫存目錄執行;-env none,不讀 .env)
bash <kit>/scripts/goose.sh <name> validate --dir <migrations>
bash <kit>/scripts/goose.sh <name> run --dir <migrations> --table <版本表> --dsn <dsn> -- up-to 53
bash <kit>/scripts/goose.sh <name> roundtrip --dir <migrations> --table <版本表> \
  --dsn <不帶旗標的 migrator DSN> --dsn-allow <帶破壞性 Down 旗標的 DSN> --from <審查的第一版> [--to <最後一版>]
# → 前一版 → up-to → down-to 前一版(不帶旗標)→ 被拒時用 --dsn-allow 再 down → up-to;每步印指令與輸出
#   最後一行 JSON:{"before","up","down_no_flag":"ok|rejected","down_with_flag":"ok|failed|no-allow-dsn|skipped","up_again","final_version","reject_message","ok"}

# 鎖(一律 ROLLBACK)
bash <kit>/scripts/locks.sh <name> --dsn <migrator> --goose-up <migration.sql>       # 交易內執行 Up,列出每個鎖與它會擋什麼
bash <kit>/scripts/locks.sh <name> --dsn <migrator> --sql '<DDL>' \
  --hold-dsn <dsn> --hold '<開著交易的語句>' --probe-dsn <app> --probe '<熱表寫入>' --monitor-dsn <superuser> [--lock-timeout 2s] [--hold-seconds 8]
# → session 快照(誰被誰擋,blocked_by 用 hold / ddl / probe)、relation 鎖快照、結果;JSON {"ddl":"timeout(55P03)|ok|error(…)","ddl_blocked_by",…}
#   NO TRANSACTION 檔(CREATE INDEX CONCURRENTLY 等)不能用 --goose-up(結束碼 1),改推導或手動 hold

# GRANT 矩陣(每項用該角色的 LOGIN DSN 實際連線執行,BEGIN … ROLLBACK)
bash <kit>/scripts/grants.sh <name> --matrix <矩陣檔> --dsn app=<mj_app DSN> --dsn admin=<…>
#   矩陣每行:<label> | <物件> | <動作> | <預期>
#   動作:select | select(c1,c2) | insert | insert(c1) | update(c1) | delete | truncate | sql:<語句,可用 {obj}>
#   預期:ok | 42501 | 其他 SQLSTATE。ok = 權限檢查通過(成功,或之後的 23xxx / 22xxx;truncate 的 0A000 FK);
#   42P01 等其他錯誤記為 error(<code>),不算 ok。→ PASS/FAIL 行 + grants total=… pass=… fail=…;有 FAIL 結束碼 1
#   insert 帶 DEFAULT 會用到序列:serial 沒有 USAGE 時得到「permission denied for sequence」(identity 欄位不需要)

# 併發(兩個 session 依腳本交錯;每步超過 --step-wait 秒沒完成就標 waiting、繼續下一步)
bash <kit>/scripts/race.sh <name> --script <腳本> --dsn A=<dsn> --dsn B=<dsn> [--check-dsn <superuser>] [--lock-timeout 10s]
#   腳本行:SETUP: <sql> / A: <sql> / B: <sql> / SLEEP: <秒> / CHECK: <sql> => <預期>(每個語句一行)
#   → 每步 done / waiting 與最終錯誤(錯誤歸到正確的步驟);JSON {"deadlock":bool,"errors":{"40P01":1},"checks":{…}};CHECK 不符結束碼 1

# 種子與效能
bash <kit>/scripts/seed.sh <name> --dsn <dsn> --file <專案種子腳本> --var n=300000          # 優先用專案的
bash <kit>/scripts/seed.sh <name> --dsn <dsn> --table <schema.表> --rows N --col "c=<用 g 的運算式>"... [--batch 100000]
bash <kit>/scripts/explain.sh <name> --dsn <dsn> --query '<SQL>' [--runs 20] [--target-ms 50]
#   → EXPLAIN (ANALYZE, BUFFERS) 全文 + JSON {"runs","p50_ms","p95_ms","max_ms","target_ms","ok"}(伺服器端規劃 + 執行時間;DML 每次 ROLLBACK)

# 分區(superuser DSN;PostgreSQL ≥ 16)
bash <kit>/scripts/pg.sh psql <name> <superuser dsn> -v min_runway_days=30 < <kit>/scripts/partitions.sql
#   → 分區與邊界、跑道天數、子表 ACL 與父表不同、FK、default 分區;最後一行 partitions_summary parents=… runway_violations=… acl_mismatches=… missing_default=…

# 專案整合測試(隔離環境)
bash <kit>/scripts/gotest.sh <name> --dir <模組目錄> --tags integration \
  --env TEST_DATABASE_URL=<dsn> --env TEST_APP_DATABASE_URL=<dsn> ... [--run <regex>] [--p 1] [--timeout 540s] [-- ./migrations/...]
#   → stderr:tests: PASS a / FAIL b / SKIP c、subtests …、每個 SKIP 的原因、每個 FAIL 的最後輸出、GAP 行
#   → stdout 最後一行 JSON {"status":"PASS|FAIL|GAP","tests":{…},"subtests":{…},"skipped":[…],"failed":[…],"elapsed_s":…}
#   結束碼 0 PASS、1 FAIL、5 GAP(SKIP > 0 或測試數 0)。完整 log:<tmp>/<name>/gotest-*.jsonl
```

## 隔離(腳本本身強制)

- **docker 只用本機**:`DOCKER_HOST` 不是 `unix://`,或目前 context 的端點不是 `unix://` / `npipe://` → 結束碼 4,不執行任何 docker 指令。
- **只連本容器**:每個 DSN 先過守門:`postgres://`、host 一定是 `127.0.0.1`、port 一定是本容器的埠;query 不能有 `host`、`hostaddr`、`port`、`service`、`servicefile`、`passfile`、`dbname`、`user`;多主機拒絕。psql 在容器內執行(DSN 改寫成容器內 `127.0.0.1:5432`),`env -i` + `PGPASSFILE=/dev/null`。
- **每個 psql session** 帶 `statement_timeout`(預設 60s,`DBREV_STATEMENT_TIMEOUT`)與 `lock_timeout`(預設 5s,`DBREV_LOCK_TIMEOUT`);kit 預設放在 `options` 前面,DSN 自己的 `options` 優先。goose session 帶 `statement_timeout=300s`。
- **go / goose 在 `env -i` 沙盒**:只有 `PATH`、`HOME=<tmp>/<name>/home`、`TMPDIR=<tmp>/<name>/gotmp`、`GOCACHE`、`GOMODCACHE`、`GOTOOLCHAIN=local`、`GOFLAGS=-mod=readonly`、`PGPASSFILE=/dev/null`、`PGSERVICEFILE=/dev/null`、Go 下載變數(`GOPROXY`、`GOSUMDB`、`GOPRIVATE`、`GONOSUMDB`、`GONOPROXY`,值取自沙盒外的 `go env`,保留 `go env -w` 的設定)與 `HTTPS_PROXY` / `HTTP_PROXY` / `NO_PROXY`,加上呼叫時用 `--env` 明確給的變數。shell 的 `DATABASE_URL`、`TEST_*`、`PG*`、`GOOSE_*` 一律不繼承。`--env` 的值是 `postgres://` 時要過守門;名稱像連線設定(`PG*`、`*DATABASE*`、`*DSN*`、`*_URL`、`*_URI`)但值不是 URL → 結束碼 4。
- **Go 快取用使用者真正的**(使用者 2026-11-22 決定):沙盒的 `GOMODCACHE` / `GOCACHE` 是沙盒外 `go env GOMODCACHE` / `go env GOCACHE` 的值(通常 `~/go/pkg/mod`、`~/Library/Caches/go-build`),不是暫存目錄,所以模組只有第一次下載。取不到時停止,不改用暫存目錄。goose CLI 與測試都用本機 Go 工具鏈,不在 Docker 裡跑。
- **專案唯讀**:掛載一律 `readonly`;goose 只讀專案的 `*.sql`(複製到暫存目錄);`GOFLAGS=-mod=readonly` 不改 go.mod / go.sum;goose CLI 編到 `<tmp>/<name>/bin/`(`GOBIN` 在暫存目錄,不是全域安裝)。
- **容器**:只操作 label `dbrev=<name>` 且名稱前綴 `dbrev-<name>-` 的容器;資料在 tmpfs(有 `size=`),沒有 volume;只綁 `127.0.0.1` 隨機埠。`pg.sh up` 失敗或中斷時 trap 刪容器;locks / race 結束時取消自己的 backend、收掉背景程序;goose / gotest 刪自己的暫存子目錄。
- `gotest.sh` 會掃 `*_test.go` 裡寫死的連線字串並警告(例如寫死 `localhost:5432`);能否排除由使用者判斷(db-reviewer 判 BLOCKED)。

腳本擋不住的(文字規則,由 db-reviewer 遵守):不讀 `.env` / secret、不用 `kubectl` / `gcloud` / `cnpg`、不 `go get` / `go mod tidy`。

## 自我測試

```bash
bash <kit>/tests/run.sh    # 需要本機 Docker 與 Go;第一次會下載 goose / pgx 模組。沒有 docker / go 的項目印 SKIP(不算通過)
```

範例專案 `tests/fixture/`:3 支 goose migration(欄位等級 GRANT + 冪等鍵、分區表(故意讓一個子表 ACL 不同)、有 GUC 守門的破壞性 Down)、init 目錄引用另外掛載的 `/roles.sql`、種子腳本、build tag `integration` 的 Go 整合測試(讀 `FX_*_DSN`,其中一個沒設時 SKIP)。測試涵蓋全部腳本、隔離(shell 帶 `DATABASE_URL` / `PG*` 不外漏、沙盒用真正的 `GOMODCACHE`、假的遠端 `DOCKER_HOST` / context 被拒)、SKIP 計數,結束時 `docker ps -a --filter label=dbrev=<測試名>` 為空;映像本來沒有時,測完刪除。

web-dev-kit 的 `pg.sh` 是開發用(postgres:17、保留資料),和這裡不共用。
