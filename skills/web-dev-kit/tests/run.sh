#!/bin/bash
# web-dev-kit 自我測試。沒有 node / docker 的項目印 skip(不算通過)。
# PostgreSQL 測試會拉映像,預設略過;要測時設 WEB_DEV_KIT_TEST_PG=1。
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/scripts"
export WEB_DEV_KIT_TMP="$(mktemp -d)/kit"
WORK="$(mktemp -d)"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
cleanup() { for n in t-serve t-busy t-child t-node-a t-node-b t-node-c; do bash "$S/stop.sh" "$n" >/dev/null 2>&1; done; [ -n "${BLOCKER:-}" ] && kill "$BLOCKER" 2>/dev/null; rm -rf "$WORK" "$(dirname "$WEB_DEV_KIT_TMP")"; }
trap cleanup EXIT

# ---------- serve / stop ----------
P="$(free_port)"
out="$(bash "$S/serve.sh" t-serve "$WORK" "$P" -- python3 -m http.server '{port}' --bind 127.0.0.1)"
if echo "$out" | grep -q "^url=http://localhost:$P port=$P pgid="; then ok "serve:啟動並回報 url/port/pgid"; else bad "serve:啟動" "$out"; fi

out2="$(bash "$S/serve.sh" t-serve "$WORK" "$P" -- python3 -m http.server '{port}' 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out2" | grep -q "已在執行"; then ok "serve:同名服務已執行時拒絕"; else bad "serve:同名拒絕" "rc=$rc $out2"; fi

out3="$(bash "$S/serve.sh" t-busy "$WORK" "$P" -- python3 -m http.server '{port}' --bind 127.0.0.1)"
if echo "$out3" | grep -q "port=$((P + 1))"; then ok "serve:埠被占用改用下一個"; else bad "serve:換埠" "$out3"; fi
bash "$S/stop.sh" t-busy >/dev/null

out="$(bash "$S/stop.sh" t-serve)"
if [ "$out" = "stopped port=$P" ] && ! lsof -nP -iTCP:"$P" -sTCP:LISTEN -t >/dev/null 2>&1; then ok "stop:停止並釋放埠"; else bad "stop" "$out"; fi
[ "$(bash "$S/stop.sh" t-serve)" = "not-running" ] && ok "stop:沒在執行印 not-running" || bad "stop:not-running"

out="$(bash "$S/serve.sh" t-early "$WORK" "$(free_port)" --timeout 10 -- sh -c 'echo boom; exit 3' 2>&1)"; rc=$?
if [ $rc -ne 0 ] && echo "$out" | grep -q "提早結束" && echo "$out" | grep -q boom; then ok "serve:指令提早結束時回報 log"; else bad "serve:提早結束" "$out"; fi

# 子程序(像 next dev / go run 會再開子程序)也要被停掉
P2="$(free_port)"
bash "$S/serve.sh" t-child "$WORK" "$P2" -- sh -c "python3 -m http.server $P2 --bind 127.0.0.1 & sleep 600; wait" >/dev/null
CHILD="$(lsof -nP -iTCP:"$P2" -sTCP:LISTEN -t | head -1)"
bash "$S/stop.sh" t-child >/dev/null
sleep 0.5
if [ -n "$CHILD" ] && ! kill -0 "$CHILD" 2>/dev/null; then ok "stop:程序群組內的子程序也被停掉"; else bad "stop:子程序" "child=$CHILD"; fi

# ---------- scope ----------
R="$WORK/repo"; mkdir -p "$R/frontend" "$R/backend"
( cd "$R" && git init -q && git config user.email t@t && git config user.name t \
  && echo a > frontend/a.txt && echo b > backend/b.txt && echo r > README.md && echo k > keep.txt \
  && git add . && git commit -qm init \
  && echo pre > backend/b.txt )            # 開工前就有的未提交變動
( cd "$R" && bash "$S/scope.sh" snapshot t-scope >/dev/null )
( cd "$R" && echo a2 > frontend/a.txt && echo new > frontend/new.txt )
out="$(cd "$R" && bash "$S/scope.sh" check t-scope frontend/)"; rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "^IN frontend/a.txt" && echo "$out" | grep -q "^IN frontend/new.txt" && ! echo "$out" | grep -q backend/b.txt; then ok "scope:範圍內變動 IN,基準前的變動不列"; else bad "scope:IN" "$out"; fi

( cd "$R" && echo pre2 > backend/b.txt )   # 基準前已修改的檔案再改
out="$(cd "$R" && bash "$S/scope.sh" check t-scope frontend/)"; rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "^OUT backend/b.txt" && echo "$out" | grep -q "out=1"; then ok "scope:基準前已修改的檔案再改要被偵測(OUT)"; else bad "scope:再改" "$out"; fi

( cd "$R" && git checkout -q -- backend/b.txt && rm keep.txt && rm frontend/new.txt )
out="$(cd "$R" && bash "$S/scope.sh" check t-scope frontend/)"
if echo "$out" | grep -q "^OUT-DEL backend/b.txt" && echo "$out" | grep -q "^OUT-DEL keep.txt"; then ok "scope:還原回 HEAD 與刪除列 OUT-DEL"; else bad "scope:DEL" "$out"; fi
out="$(cd "$R" && bash "$S/scope.sh" check t-scope)"; rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "^OUT frontend/a.txt"; then ok "scope:零個可寫路徑時全部算 OUT"; else bad "scope:零路徑" "$out"; fi

# ---------- secret-scan ----------
( cd "$R" && git checkout -q -- . && git clean -qfd && bash "$S/scope.sh" snapshot t-sec >/dev/null \
  && printf 'const apiKey = "abcd1234efgh5678";\n' > frontend/leak.ts \
  && printf 'password: "dev-pass-123456"\nNEXT_PUBLIC_API_URL=x\n' > frontend/ok.ts \
  && printf 'token = "realtoken123456"\n' > frontend/x.test.ts \
  && bash "$S/scope.sh" check t-sec frontend/ >/dev/null )
out="$(cd "$R" && bash "$S/secret-scan.sh" t-sec)"; rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "hits=1" && echo "$out" | grep -q "leak.ts" && ! echo "$out" | grep -q abcd1234; then ok "secret-scan:命中並遮蔽、排除假值與測試檔"; else bad "secret-scan" "$out"; fi
( cd "$R" && printf 'NEXT_PUBLIC_STRIPE_SECRET=1\n' > frontend/env.ts && bash "$S/scope.sh" check t-sec frontend/ >/dev/null )
out="$(cd "$R" && bash "$S/secret-scan.sh" t-sec)"
if echo "$out" | grep -q "env.ts" ; then ok "secret-scan:NEXT_PUBLIC_*SECRET"; else bad "secret-scan:NEXT_PUBLIC" "$out"; fi

# ---------- node 腳本 ----------
if command -v node >/dev/null 2>&1; then
  JAR="$WORK/cookies.txt"
  printf '# Netscape HTTP Cookie File\n#HttpOnly_localhost\tFALSE\t/\tFALSE\t0\tsession\ttest-abc\nlocalhost\tFALSE\t/\tFALSE\t0\ttheme\tdark\n' > "$JAR"
  out="$(node --input-type=module -e "import {readCookieJar,cookieHeader} from '$S/cookiejar.mjs'; console.log(cookieHeader(readCookieJar('$JAR')))")"
  [ "$out" = "session=test-abc; theme=dark" ] && ok "cookiejar:讀到 #HttpOnly_ 行" || bad "cookiejar" "$out"

  # 兩個小型 node 伺服器:回聲 body / cookie,用來測 proxy-diff
  SRV="$WORK/srv.mjs"
  cat > "$SRV" <<'JS'
import http from 'node:http';
const [port, variant] = process.argv.slice(2);
http.createServer((req, res) => {
  let b = ''; req.on('data', c => b += c); req.on('end', () => {
    res.setHeader('Content-Type', 'application/json');
    const body = b ? JSON.parse(b) : {};
    res.end(JSON.stringify({ id: Math.random(), email: body.email ?? null, cookie: req.headers.cookie ?? null, extra: variant === 'b' ? 1 : undefined }));
  });
}).listen(Number(port), '127.0.0.1');
JS
  PA="$(free_port)"; PB="$(free_port)"
  bash "$S/serve.sh" t-node-a "$WORK" "$PA" -- node "$SRV" '{port}' a >/dev/null
  bash "$S/serve.sh" t-node-b "$WORK" "$PB" -- node "$SRV" '{port}' b >/dev/null
  out="$(node "$S/proxy-diff.mjs" "http://127.0.0.1:$PA" "http://127.0.0.1:$PA" POST /x --data '{"email":"u{uniq}@x"}' --ignore id --structure)"
  echo "$out" | grep -q '"same":true' && ok "proxy-diff:--structure 相同結構" || bad "proxy-diff:structure" "$out"
  out="$(node "$S/proxy-diff.mjs" "http://127.0.0.1:$PA" "http://127.0.0.1:$PA" POST /x --data '{"email":"u{uniq}@x"}' --ignore id)"; rc=$?
  [ $rc -eq 1 ] && echo "$out" | grep -q '"path":"\$.email"' && ok "proxy-diff:{uniq} 兩邊不同、body 比對抓得到" || bad "proxy-diff:uniq" "$out"
  out="$(node "$S/proxy-diff.mjs" "http://127.0.0.1:$PA" "http://127.0.0.1:$PB" GET /x --ignore id --structure)"; rc=$?
  [ $rc -eq 1 ] && echo "$out" | grep -q 'extra' && ok "proxy-diff:結構不同時失敗" || bad "proxy-diff:diff" "$out"
  # concurrency:伺服器同時處理中的請求超過 1 個就回 500,模擬 SQLITE_BUSY
  CSRV="$WORK/csrv.mjs"
  cat > "$CSRV" <<'JS'
import http from 'node:http';
let busy = 0; const seen = new Set();
http.createServer((req, res) => {
  let b = ''; req.on('data', c => b += c); req.on('end', () => {
    if (req.url === '/') { res.end('ok'); return; }
    if (req.url === '/dup') { const e = JSON.parse(b).email; const dup = seen.has(e); seen.add(e); res.statusCode = dup ? 409 : 201; res.end('{}'); return; }
    busy++; setTimeout(() => { res.statusCode = busy > 1 ? 500 : 200; busy--; res.end('{"error":{"code":"internal_error"}}'); }, 50);
  });
}).listen(Number(process.argv[2]), '127.0.0.1');
JS
  PC="$(free_port)"; bash "$S/serve.sh" t-node-c "$WORK" "$PC" -- node "$CSRV" '{port}' >/dev/null
  out="$(node "$S/concurrency.mjs" "http://127.0.0.1:$PC" POST /busy -n 5)"; rc=$?
  [ $rc -eq 1 ] && echo "$out" | grep -q '"500"' && echo "$out" | grep -q '"ok":false' && ok "concurrency:並發下的 5xx 被抓到" || bad "concurrency:5xx" "$out"
  out="$(node "$S/concurrency.mjs" "http://127.0.0.1:$PC" POST /dup -n 5 --data '{"email":"u{uniq}@x"}' --expect 201)"
  echo "$out" | grep -q '"ok":true' && ok "concurrency:{uniq} 每個請求不同(全部 201)" || bad "concurrency:uniq" "$out"
  bash "$S/stop.sh" t-node-c >/dev/null
  out="$(node "$S/proxy-diff.mjs" "http://127.0.0.1:$PA" "http://127.0.0.1:$PA" GET /x --ignore id --cookie-jar "$JAR")"
  echo "$out" | grep -q '"same":true' && ok "proxy-diff:cookie-jar 帶上 cookie 且相同" || bad "proxy-diff:cookie" "$out"

  if [ -x "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" ]; then
    PAGE="$WORK/site"; mkdir -p "$PAGE"
    printf '<!doctype html><meta name=viewport content="width=device-width"><body style="margin:0"><div style="height:2000px">ok</div><script>document.title=document.cookie</script></body>' > "$PAGE/index.html"
    printf '<!doctype html><meta name=viewport content="width=device-width"><body style="margin:0"><div style="width:900px">wide</div><script>console.error("boom")</script></body>' > "$PAGE/bad.html"
    PS="$(free_port)"; bash "$S/serve.sh" t-serve "$PAGE" "$PS" -- python3 -m http.server '{port}' --bind 127.0.0.1 >/dev/null
    out="$(node "$S/shot.mjs" "http://localhost:$PS/" 1280 800 "$WORK/d.png")"; rc=$?
    if [ $rc -eq 0 ] && echo "$out" | grep -q '"http":200' && echo "$out" | grep -q '"scrollWidth":1280' && echo "$out" | grep -q '"pageHeight":2000' && [ -s "$WORK/d.png" ]; then ok "shot:桌面整頁截圖"; else bad "shot:桌面" "$out"; fi
    H="$(sips -g pixelHeight "$WORK/d.png" 2>/dev/null | awk '/pixelHeight/{print $2}')"
    [ "${H:-0}" -ge 2000 ] && ok "shot:截到整頁高度($H px)" || bad "shot:整頁" "height=$H"
    out="$(node "$S/shot.mjs" "http://localhost:$PS/bad.html" 390 844 "$WORK/m.png" --mobile)"; rc=$?
    if [ $rc -eq 2 ] && echo "$out" | grep -q '"scrollWidth":900' && echo "$out" | grep -q '"innerWidth":390' && echo "$out" | grep -q '"consoleErrors":1'; then ok "shot:手機版抓到橫向捲動與 console 錯誤"; else bad "shot:手機" "$out"; fi
    W="$(sips -g pixelWidth "$WORK/m.png" 2>/dev/null | awk '/pixelWidth/{print $2}')"
    [ "${W:-0}" -ge 2700 ] && ok "shot:手機 PNG 含整個過寬內容(900 CSS px × 3 = $W px)" || bad "shot:手機寬度" "$W"
    LEFT="$(ps -A -o command= | grep -c '[w]eb-dev-kit-chrome-')"
    [ "$LEFT" -eq 0 ] && ok "shot:結束後沒有殘留 Chrome" || bad "shot:殘留 Chrome" "$LEFT"
    bash "$S/stop.sh" t-serve >/dev/null
  else
    skip "shot:沒有 Google Chrome"
  fi
else
  skip "cookiejar / proxy-diff / shot:沒有 node"
fi

# ---------- pg ----------
if [ "${WEB_DEV_KIT_TEST_PG:-0}" = "1" ] && docker info >/dev/null 2>&1; then
  HAD_IMAGE=0; docker image inspect postgres:17 >/dev/null 2>&1 && HAD_IMAGE=1
  out="$(bash "$S/pg.sh" up kittest)"
  echo "$out" | grep -q '^DATABASE_URL=postgres://dev:devpass@127.0.0.1:' && ok "pg:up" || bad "pg:up" "$out"
  bash "$S/pg.sh" down kittest >/dev/null && ok "pg:down" || bad "pg:down"
  docker rm -f dev-kittest-pg >/dev/null 2>&1
  [ "$HAD_IMAGE" = "0" ] && docker rmi postgres:17 >/dev/null 2>&1   # 測試才拉的映像要刪
else
  skip "pg:未設 WEB_DEV_KIT_TEST_PG=1 或 Docker 沒開"
fi

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
