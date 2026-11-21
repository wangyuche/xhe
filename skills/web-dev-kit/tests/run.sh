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
# Go 寫法::=、var x string =、var x =、反引號、名稱帶後綴;dev- 假值與比較式(==)不算
( cd "$R" && rm -f frontend/env.ts frontend/leak.ts && mkdir -p backend && cat > backend/conf.go <<'GO'
package conf
func f() {
	token := "realtoken123456"
	var sessionSecret string = "s3cr3tvalue999"
	var apiKey = `rawkey12345678`
	const jwtSecretKey = "jwtsecret12345"
	devToken := "dev-token-123456"
	if password == "notasecret1" {
	}
}
GO
bash "$S/scope.sh" check t-sec frontend/ backend/ >/dev/null )
out="$(cd "$R" && bash "$S/secret-scan.sh" t-sec)"; rc=$?
if [ $rc -eq 1 ] && echo "$out" | grep -q "hits=4" && echo "$out" | grep -q "conf.go:3:" && echo "$out" | grep -q "conf.go:4:" && echo "$out" | grep -q "conf.go:5:" && echo "$out" | grep -q "conf.go:6:" \
  && ! echo "$out" | grep -qE "realtoken|s3cr3t|rawkey|jwtsecret"; then ok "secret-scan:Go 的 :=、var 帶型別、反引號、名稱後綴"; else bad "secret-scan:Go" "$out"; fi

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
    echo "$out" | grep -q '"redirected":false' && ok "shot:沒轉址時 redirected=false" || bad "shot:redirected=false" "$out"
    # 伺服器轉址(http.server 把 /sub 301 到 /sub/,像沒登入被導到 /login):http 雖是 200 也要失敗
    mkdir -p "$PAGE/sub"; printf '<!doctype html><body>login</body>' > "$PAGE/sub/index.html"
    out="$(node "$S/shot.mjs" "http://localhost:$PS/sub" 1280 800 "$WORK/r.png")"; rc=$?
    if [ $rc -eq 2 ] && echo "$out" | grep -q '"http":200' && echo "$out" | grep -q '"redirected":true' && echo "$out" | grep -q "\"finalUrl\":\"http://localhost:$PS/sub/\"" && echo "$out" | grep -q '"redirect: '; then ok "shot:伺服器轉址判失敗並回報 finalUrl"; else bad "shot:伺服器轉址" "rc=$rc $out"; fi
    out="$(node "$S/shot.mjs" "http://localhost:$PS/sub" 1280 800 "$WORK/r.png" --allow-redirect)"; rc=$?
    [ $rc -eq 0 ] && echo "$out" | grep -q '"redirected":true' && ok "shot:--allow-redirect 時轉址不算失敗" || bad "shot:--allow-redirect" "rc=$rc $out"
    # 頁面 JS 轉址(用戶端導向登入頁):fetch 看不到,要靠 Chrome 最後的網址
    printf '<!doctype html><script>location.replace("/sub/")</script>' > "$PAGE/js.html"
    out="$(node "$S/shot.mjs" "http://localhost:$PS/js.html" 1280 800 "$WORK/j.png")"; rc=$?
    [ $rc -eq 2 ] && echo "$out" | grep -q "\"finalUrl\":\"http://localhost:$PS/sub/\"" && ok "shot:JS 轉址也判失敗" || bad "shot:JS 轉址" "rc=$rc $out"
    LEFT="$(ps -A -o command= | grep -c '[w]eb-dev-kit-chrome-')"
    [ "$LEFT" -eq 0 ] && ok "shot:結束後沒有殘留 Chrome" || bad "shot:殘留 Chrome" "$LEFT"
    bash "$S/stop.sh" t-serve >/dev/null
  else
    skip "shot:沒有 Google Chrome"
  fi
else
  skip "cookiejar / proxy-diff / shot:沒有 node"
fi

# ---------- compose(離線:用 PATH 上的假 docker,不碰真的 Docker)----------
FAKE="$WORK/fakebin"; FD="$WORK/fakedocker"; mkdir -p "$FAKE" "$FD"
cat > "$FAKE/docker" <<'SH'
#!/bin/bash
# 假 docker:記錄呼叫;行為由 $FD 下的檔案決定
FD="${FAKE_DOCKER_DIR:?}"
echo "$*" >> "$FD/calls"
[ "${1:-}" = info ] && { [ -f "$FD/info-fail" ] && exit 1; exit 0; }
[ "${1:-}" = compose ] || exit 0
shift
[ "${1:-}" = version ] && { echo "Docker Compose version v9-fake"; exit 0; }
while [ $# -gt 0 ]; do case "$1" in -p|-f) shift 2 ;; *) break ;; esac; done
case "$1" in
  config) cat "$FD/config.json" ;;
  up) [ -f "$FD/up-fail" ] && exit 1; touch "$FD/started"; exit 0 ;;
  port) [ -f "$FD/started" ] && [ -f "$FD/port.$2.$3" ] && cat "$FD/port.$2.$3"; exit 0 ;;
  ps)
    if [ "${3:-}" = --format ]; then
      n="$(cat "$FD/ps-n" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$FD/ps-n"
      while [ ! -f "$FD/ps.$n" ] && [ "$n" -gt 1 ]; do n=$((n - 1)); done
      cat "$FD/ps.$n" 2>/dev/null
    else echo "FAKE-PS-TABLE"; fi ;;
  logs) echo "FAKE-LOGS $*" ;;
  *) exit 0 ;;
esac
SH
chmod +x "$FAKE/docker"
export FAKE_DOCKER_DIR="$FD"
fake_reset() { rm -f "$FD"/*; echo '{"services":{"frontend":{"ports":[{"host_ip":"127.0.0.1","target":3000,"published":"'"${1:-3999}"'"}]},"backend":{}}}' > "$FD/config.json"; }
C="$S/compose.sh"
CP="$WORK/cproj/myshop"; mkdir -p "$CP"
printf 'services:\n  frontend:\n    ports: ["127.0.0.1:${WEB_PORT:-%s}:3000"]\n' 3999 > "$CP/compose.yaml"
fc() { ( cd "$CP" && PATH="$FAKE:$PATH" COMPOSE_SH_POLL=0.2 bash "$C" "$@" ); }

fake_reset
out="$(fc up 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "缺少 -p" && [ ! -f "$FD/calls" ] && ok "compose:缺 -p 拒絕(不呼叫 docker)" || bad "compose:缺 -p" "rc=$rc $out"
out="$(fc up -p Bad_Name 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "小寫英文" && ok "compose:專案名格式檢查" || bad "compose:名稱格式" "rc=$rc $out"
out="$(fc start -p kit-x 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "未知子命令" && ok "compose:未知子命令" || bad "compose:子命令" "rc=$rc $out"
out="$(fc logs -p kit-x 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "logs -p" && ok "compose:logs 缺服務名" || bad "compose:logs 參數" "rc=$rc $out"
out="$(fc down -p kit-x --build 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "只用在 up" && ok "compose:選項不屬於子命令時拒絕" || bad "compose:選項" "rc=$rc $out"
out="$(fc up -p myshop 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "預設專案名" && [ ! -f "$FD/calls" ] && ok "compose:拒絕目錄預設專案名" || bad "compose:預設名" "rc=$rc $out"
out="$(cd "$CP" && COMPOSE_PROJECT_NAME=other-proj PATH="$FAKE:$PATH" bash "$C" down -p other-proj 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "預設專案名" && ok "compose:拒絕 COMPOSE_PROJECT_NAME" || bad "compose:COMPOSE_PROJECT_NAME" "rc=$rc $out"
printf 'export COMPOSE_PROJECT_NAME="envproj"  # 使用者的\n' > "$CP/.env"
out="$(cd "$CP" && PATH="$FAKE:$PATH" bash "$C" down -p envproj --volumes 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "預設專案名" && ok "compose:拒絕 .env 裡的 COMPOSE_PROJECT_NAME" || bad "compose:.env 專案名" "rc=$rc $out"
rm -f "$CP/.env"
out="$(fc down -p myshop --allow-default 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q -- "-p myshop" "$FD/calls" && ok "compose:--allow-default 放行" || bad "compose:--allow-default" "rc=$rc $out"

fake_reset; touch "$FD/info-fail"
out="$(fc ps -p kit-x 2>&1)"; rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q "Docker 沒有在執行" && ok "compose:Docker 沒開結束碼 3" || bad "compose:Docker 沒開" "rc=$rc $out"
NODOCKER="$WORK/nodocker"; mkdir -p "$NODOCKER"; for t in bash sed grep tr basename dirname head lsof; do ln -sf "$(command -v $t)" "$NODOCKER/$t"; done
out="$(cd "$CP" && PATH="$NODOCKER" bash "$C" ps -p kit-x 2>&1)"; rc=$?
[ $rc -eq 3 ] && echo "$out" | grep -q "找不到 docker" && ok "compose:沒有 docker 指令結束碼 3" || bad "compose:沒有 docker" "rc=$rc $out"

# up:starting → healthy,印 url;down 預設保留 volume
fake_reset
printf 'db|running|starting|0\nbackend|created||0\nfrontend|created||0\n' > "$FD/ps.1"
printf 'db|running|healthy|0\nbackend|running|healthy|0\nmigrate|exited||0\nfrontend|running|healthy|0\n' > "$FD/ps.3"
echo "127.0.0.1:3999" > "$FD/port.frontend.3000"
out="$(fc up -p kit-x 2>&1)"; rc=$?
if [ $rc -eq 0 ] && echo "$out" | grep -q "^url=http://localhost:3999 port=3999 service=frontend$" && echo "$out" | grep -q "^up project=kit-x" \
   && grep -q -- "-p kit-x -f $CP/compose.yaml up -d$" "$FD/calls"; then ok "compose:up -d、等到 healthy、印 url/port"; else bad "compose:up" "rc=$rc $out"; fi
fc down -p kit-x >/dev/null 2>&1
grep -E -- "-p kit-x .*down$" "$FD/calls" >/dev/null && ok "compose:down 預設不刪 volume" || bad "compose:down" "$(tail -1 "$FD/calls")"
printf 'services: {}\n' > "$CP/compose.override.yaml"; fake_reset
out="$(fc ps -p kit-x 2>&1)"; grep -q -- "-f $CP/compose.yaml -f $CP/compose.override.yaml" "$FD/calls" && ok "compose:自動找到的檔案也帶上 compose.override.yaml" || bad "compose:override" "$(cat "$FD/calls")"
rm -f "$CP/compose.override.yaml"
out="$(fc down -p kit-x --volumes --images 2>&1)"
grep -E -- "down --volumes --rmi local$" "$FD/calls" >/dev/null && echo "$out" | grep -q "volumes=removed" && ok "compose:down --volumes --images" || bad "compose:down --volumes" "$out"

fake_reset; printf 'db|running|starting|0\n' > "$FD/ps.1"
out="$(fc up -p kit-x --timeout 1 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "沒有全部就緒" && echo "$out" | grep -q "FAKE-PS-TABLE" && echo "$out" | grep -q "FAKE-LOGS" && ok "compose:逾時結束碼 1 並印 ps 與 log" || bad "compose:逾時" "rc=$rc $out"
fake_reset; printf 'db|running|healthy|0\nbackend|running|unhealthy|0\n' > "$FD/ps.1"
out="$(fc up -p kit-x 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "backend(unhealthy)" && ok "compose:unhealthy 立即失敗" || bad "compose:unhealthy" "rc=$rc $out"
fake_reset; printf 'backend|exited||2\n' > "$FD/ps.1"
out="$(fc up -p kit-x 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$out" | grep -q "backend(exited,exit=2)" && ok "compose:容器非 0 結束時失敗" || bad "compose:exited" "rc=$rc $out"

# 對外埠被占用:結束碼 4、建議換埠變數、不呼叫 up
PB="$(free_port)"
bash "$S/serve.sh" t-busy "$WORK" "$PB" -- python3 -m http.server '{port}' --bind 127.0.0.1 >/dev/null
printf 'services:\n  frontend:\n    ports: ["127.0.0.1:${WEB_PORT:-%s}:3000"]\n' "$PB" > "$CP/compose.yaml"
fake_reset "$PB"
out="$(fc up -p kit-x 2>&1)"; rc=$?
[ $rc -eq 4 ] && echo "$out" | grep -q "$PB 已被占用" && echo "$out" | grep -q "WEB_PORT=" && ! grep -q " up " "$FD/calls" && ok "compose:埠被占用結束碼 4、建議 WEB_PORT、不 up" || bad "compose:埠被占用" "rc=$rc $out"
# 寫死主機埠(沒有 ${VAR:-埠})被占用:仍結束碼 4 並說明,不能因 pipefail 無訊息結束
printf 'services:\n  frontend:\n    ports: ["127.0.0.1:%s:3000"]\n' "$PB" > "$CP/compose.yaml"
fake_reset "$PB"
out="$(fc up -p kit-x 2>&1)"; rc=$?
[ $rc -eq 4 ] && echo "$out" | grep -q "$PB 已被占用" && ! grep -q " up " "$FD/calls" && ok "compose:寫死的埠被占用也結束碼 4 並說明" || bad "compose:寫死埠被占用" "rc=$rc $out"
printf 'services:\n  frontend:\n    ports: ["127.0.0.1:${WEB_PORT:-%s}:3000"]\n' 3999 > "$CP/compose.yaml"
bash "$S/stop.sh" t-busy >/dev/null

# ---------- pg ----------
if [ "${WEB_DEV_KIT_TEST_PG:-0}" = "1" ] && docker info >/dev/null 2>&1; then
  HAD_IMAGE=0; docker image inspect postgres:17 >/dev/null 2>&1 && HAD_IMAGE=1
  out="$(bash "$S/pg.sh" up kittest)"
  echo "$out" | grep -q '^DATABASE_URL=postgres://dev:devpass@127.0.0.1:' && ok "pg:up" || bad "pg:up" "$out"
  bash "$S/pg.sh" down kittest >/dev/null && ok "pg:down" || bad "pg:down"
  [ -n "$(docker ps -a --filter name=^/dev-kittest-pg$ --format '{{.Names}}')" ] && ok "pg:down 保留容器" || bad "pg:down 保留容器"
  VOL="$(docker inspect -f '{{range .Mounts}}{{.Name}} {{end}}' dev-kittest-pg 2>/dev/null)"
  out="$(bash "$S/pg.sh" rm kittest)"
  [ "$out" = "removed container=dev-kittest-pg" ] && [ -z "$(docker ps -a --filter name=^/dev-kittest-pg$ --format '{{.Names}}')" ] && ok "pg:rm 刪容器" || bad "pg:rm" "$out"
  LEFTVOL=0; for v in $VOL; do docker volume inspect "$v" >/dev/null 2>&1 && LEFTVOL=1; done
  [ -n "$VOL" ] && [ "$LEFTVOL" = 0 ] && ok "pg:rm 刪資料 volume" || bad "pg:rm volume" "vol=$VOL"
  out="$(bash "$S/pg.sh" rm kittest)"; [ "$out" = "not-found container=dev-kittest-pg" ] && ok "pg:rm 不存在時不報錯" || bad "pg:rm 不存在" "$out"
  docker rm -f -v dev-kittest-pg >/dev/null 2>&1
  [ "$HAD_IMAGE" = "0" ] && docker rmi postgres:17 >/dev/null 2>&1   # 測試才拉的映像要刪
else
  skip "pg:未設 WEB_DEV_KIT_TEST_PG=1 或 Docker 沒開"
fi

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
