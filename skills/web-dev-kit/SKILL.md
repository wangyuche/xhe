---
name: web-dev-kit
description: 網站開發驗證用的固定腳本:背景啟動 / 停止 dev server(整個程序群組)、找可用埠、Chrome headless 整頁截圖(CDP,含 scrollWidth 與 console 錯誤)、前端轉發與後端直連比對、git 範圍檢查(相對基準)、秘密掃描、本機 PostgreSQL 容器、docker compose 整站啟停(專案名隔離、等 healthy)。frontend-owner、backend-owner、integration-verifier 驗證時使用;任何要在本機啟動網站並驗證的情境也可用。
---

# web-dev-kit

`<kit>` = 這個 skill 的目錄。所有輸出放 `${WEB_DEV_KIT_TMP:-$TMPDIR/web-dev-kit}/<name>/`,不寫進專案。

`<name>`:小寫英文、數字、連字號。預設 `<agent>-<專案名>`,`<專案名>` = 專案根目錄 basename 轉小寫、非 `[a-z0-9-]` 換成 `-`。平行派工時主 agent 給唯一名稱。

## 腳本

```bash
# 背景啟動(新程序群組),等到 HTTP < 500 才返回 → url=… port=… pgid=… log=…
bash <kit>/scripts/serve.sh <name> <dir> <起始埠> [--health /healthz] [--timeout 90] [--env K=V]... -- <指令...>
#   指令中的 {port} 會被換成實際埠,也會設 PORT。同名服務在跑時拒絕。
bash <kit>/scripts/stop.sh <name>                # → stopped port=<埠>(或 not-running)

# 整頁截圖(Node 22 內建模組 + 本機 Google Chrome)→ 一行 JSON;HTTP≠200、有 console 錯誤或被轉址時結束碼 2
node <kit>/scripts/shot.mjs <url> 1280 800 <out.png>
node <kit>/scripts/shot.mjs <url> 390 844 <out.png> --mobile [--cookie k=v] [--cookie-jar <curl -c 檔>] [--header 'K: V'] [--allow-redirect]
#   檢查:http == 200、redirected == false(finalUrl 等於請求網址;要登入的頁被導到 /login 時 http 仍是 200,
#   只有這項會抓到)、consoleErrors == 0、scrollWidth <= innerWidth(無橫向捲動);再用 Read 看圖。
#   --allow-redirect 只用在本來就該轉址的網址(例如測「沒登入會導到登入頁」)
#   --viewport:只截一屏(可帶 #錨點);整頁像素高超過 16384 時 warnings 會提醒(Chrome 會重複拼接),長頁改用 --viewport
#   本機靜態 HTML:給絕對路徑(或 file:// 網址),段落加 --anchor <id>;不做 HTTP 檢查,檔案存在記 http 200、不存在記 0 並結束碼 2;不能加 --cookie / --header

# 前端轉發 vs 後端直連 → 一行 JSON,不一致結束碼 1
node <kit>/scripts/proxy-diff.mjs <前端url> <後端url> <方法> <路徑> [--data '{"email":"u{uniq}@x"}'] [--cookie-jar <檔>] [--ignore id]... [--structure]
#   冪等端點用預設(比 body);非冪等(POST 建立)用 --structure 與 {uniq}

# 並發檢查:同時送 N 個相同請求 → {"n":10,"statuses":{"200":10},"ok":true};有 5xx / 連線錯誤 / 不在 --expect 內結束碼 1
node <kit>/scripts/concurrency.mjs <url> <方法> <路徑> [-n 10] [--data '{"email":"u{uniq}@x"}'] [--cookie-jar <檔>] [--expect 200,201]

# 範圍檢查(在專案根目錄執行)
bash <kit>/scripts/scope.sh snapshot <name>                 # 第 0 步記基準
bash <kit>/scripts/scope.sh check <name> frontend/ ...      # IN / OUT / IN-DEL / OUT-DEL,in=… out=…;out>0 結束碼 1
bash <kit>/scripts/scope.sh check <name> --exclude src/gen/ src/ ...   # 排除路徑(可重複)下的變動一律算 OUT
bash <kit>/scripts/secret-scan.sh <name>                    # 掃最近一次 check 的 IN 檔 → hits=…

# 本機 PostgreSQL(容器 dev-<專案名>-pg,postgres:17,dev/devpass,資料庫 app)
bash <kit>/scripts/pg.sh up <專案名>      # → DATABASE_URL=postgres://…
bash <kit>/scripts/pg.sh schema <專案名> <表>
bash <kit>/scripts/pg.sh down <專案名>    # 只 stop,不刪資料(開發資料庫用)。Docker 沒開:結束碼 3
bash <kit>/scripts/pg.sh rm <專案名>      # 刪容器與資料 volume → removed / not-found。只用在暫存 / 驗證用的專案名

# docker compose 整站(在 compose 檔所在目錄執行,或 -f 指定)。-p <專案名> 必填
bash <kit>/scripts/compose.sh build -p <專案名> [<服務>...]
bash <kit>/scripts/compose.sh up -p <專案名> [--build] [--timeout 180]
#   up -d → 等所有有 healthcheck 的服務 healthy(沒 healthcheck 的要 running,一次性的要 exit 0)
#   → 每個對外埠一行 url=http://localhost:<埠> port=<埠> service=<服務>,最後 up project=… services=…
#   unhealthy / 容器非 0 結束 / 逾時:結束碼 1,stderr 印 ps -a 與最後 50 行 log
#   對外埠被別的程式占用:結束碼 4,印占用者與建議的環境變數(例如 FRONTEND_PORT=3001),不 up、不停任何容器
bash <kit>/scripts/compose.sh ps -p <專案名>
bash <kit>/scripts/compose.sh logs -p <專案名> <服務> [--tail 200]   # 不 follow
bash <kit>/scripts/compose.sh down -p <專案名> [--volumes] [--images]  # 預設保留 volume 與映像
#   Docker 沒開或沒有 docker compose:結束碼 3
```

範例 compose 檔:`<kit>/templates/docker-compose.yml`(複製到專案根目錄)。db(postgres:17,`pg_isready` healthcheck,named volume)→ backend(依 db healthy,`/server healthcheck`,只 `expose` 不對外)→ frontend(依 backend healthy,`BACKEND_URL=http://backend:8080`,唯一對外埠 `127.0.0.1:${FRONTEND_PORT:-3000}`)。

## 規則

- 背景程序只用 `serve.sh` 啟動;結束前(含失敗時)一定 `stop.sh`。不要用 `&`、`nohup`、`go run` 自己開。
- 後端先 `go build -o <tmp>/<name>/server ./cmd/server` 再交給 `serve.sh`(`go run` 會多一層子程序)。
- `scope.sh` 只能判斷「這個 checkout」的變動,平行的寫入 agent 必須在不同 worktree。
- `shot.mjs` 每次用暫存的 Chrome profile,結束時關閉 Chrome 並刪除 profile。
- Docker 只透過 `pg.sh` / `compose.sh`,不直接 `docker run` / `docker compose` / `docker stop`。
- `compose.sh` 的專案名:預設 `dev-<專案名>`;驗證用的暫存專案用 `kit-test-<時間戳>` 之類的唯一名稱。不能等於 compose 預設專案名(目錄 basename、`COMPOSE_PROJECT_NAME`、compose 檔 `name:`),那可能是使用者自己 `docker compose up` 的專案;只有使用者明確要求時才加 `--allow-default`。
- `compose.sh down` 預設保留 volume(資料庫資料);只有暫存 / 測試專案或使用者要求時才 `--volumes`。暫存專案收尾:`down --volumes --images`。
- compose 檔的對外埠一律綁 `127.0.0.1`(`compose.sh up` 遇到綁所有介面的埠會警告),埠寫成 `${X_PORT:-預設}` 讓埠衝突時可換。

## 自我測試

```bash
bash <kit>/tests/run.sh                         # 沒有 node / Chrome 的項目印 SKIP(不算通過);compose.sh 用假 docker 離線測
WEB_DEV_KIT_TEST_PG=1 bash <kit>/tests/run.sh   # 加測 PostgreSQL(會拉映像,測完刪除本來沒有的映像)
```
