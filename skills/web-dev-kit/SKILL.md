---
name: web-dev-kit
description: 網站開發驗證用的固定腳本:背景啟動 / 停止 dev server(整個程序群組)、找可用埠、Chrome headless 整頁截圖(CDP,含 scrollWidth 與 console 錯誤)、前端轉發與後端直連比對、git 範圍檢查(相對基準)、秘密掃描、本機 PostgreSQL 容器。frontend-owner、backend-owner、integration-verifier 驗證時使用;任何要在本機啟動網站並驗證的情境也可用。
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

# 整頁截圖(Node 22 內建模組 + 本機 Google Chrome)→ 一行 JSON;HTTP≠200 或有 console 錯誤時結束碼 2
node <kit>/scripts/shot.mjs <url> 1280 800 <out.png>
node <kit>/scripts/shot.mjs <url> 390 844 <out.png> --mobile [--cookie k=v] [--cookie-jar <curl -c 檔>] [--header 'K: V']
#   檢查:http == 200、consoleErrors == 0、scrollWidth <= innerWidth(無橫向捲動);再用 Read 看圖

# 前端轉發 vs 後端直連 → 一行 JSON,不一致結束碼 1
node <kit>/scripts/proxy-diff.mjs <前端url> <後端url> <方法> <路徑> [--data '{"email":"u{uniq}@x"}'] [--cookie-jar <檔>] [--ignore id]... [--structure]
#   冪等端點用預設(比 body);非冪等(POST 建立)用 --structure 與 {uniq}

# 並發檢查:同時送 N 個相同請求 → {"n":10,"statuses":{"200":10},"ok":true};有 5xx / 連線錯誤 / 不在 --expect 內結束碼 1
node <kit>/scripts/concurrency.mjs <url> <方法> <路徑> [-n 10] [--data '{"email":"u{uniq}@x"}'] [--cookie-jar <檔>] [--expect 200,201]

# 範圍檢查(在專案根目錄執行)
bash <kit>/scripts/scope.sh snapshot <name>                 # 第 0 步記基準
bash <kit>/scripts/scope.sh check <name> frontend/ ...      # IN / OUT / IN-DEL / OUT-DEL,in=… out=…;out>0 結束碼 1
bash <kit>/scripts/secret-scan.sh <name>                    # 掃最近一次 check 的 IN 檔 → hits=…

# 本機 PostgreSQL(容器 dev-<專案名>-pg,postgres:17,dev/devpass,資料庫 app)
bash <kit>/scripts/pg.sh up <專案名>      # → DATABASE_URL=postgres://…
bash <kit>/scripts/pg.sh schema <專案名> <表>
bash <kit>/scripts/pg.sh down <專案名>    # 只 stop,不刪資料。Docker 沒開:結束碼 3
```

## 規則

- 背景程序只用 `serve.sh` 啟動;結束前(含失敗時)一定 `stop.sh`。不要用 `&`、`nohup`、`go run` 自己開。
- 後端先 `go build -o <tmp>/<name>/server ./cmd/server` 再交給 `serve.sh`(`go run` 會多一層子程序)。
- `scope.sh` 只能判斷「這個 checkout」的變動,平行的寫入 agent 必須在不同 worktree。
- `shot.mjs` 每次用暫存的 Chrome profile,結束時關閉 Chrome 並刪除 profile。

## 自我測試

```bash
bash <kit>/tests/run.sh                         # 沒有 node / Chrome 的項目印 SKIP(不算通過)
WEB_DEV_KIT_TEST_PG=1 bash <kit>/tests/run.sh   # 加測 PostgreSQL(會拉映像,測完刪除本來沒有的映像)
```
