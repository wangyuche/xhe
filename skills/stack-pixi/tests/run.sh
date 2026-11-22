#!/bin/bash
# stack-pixi 自我測試:建骨架 → npm ci → tsc / vitest / build / 四個檢查(含故意違規)/ 素材管線 / E2E 全尺寸 / perf 一次 / Worker 限速。
# 需要網路(npm registry)、本機 Google Chrome、同層的 game-art-kit 與 web-dev-kit。測完刪除暫存、停止服務。
set -uo pipefail
K="$(cd "$(dirname "$0")/.." && pwd)"
WK="$K/../web-dev-kit/scripts"
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | tail -20 | sed 's/^/      /'; FAIL=$((FAIL + 1)); }
t()   { local name=$1; shift; local out; if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$out"; fi; }
tf()  { local name=$1; shift; local out; if out=$("$@" 2>&1); then bad "$name(應失敗)" "$out"; else ok "$name"; fi; }
W="$(mktemp -d)"; N="sptest$$"
cleanup() { bash "$WK/stop.sh" "$N-dev" >/dev/null 2>&1; bash "$WK/stop.sh" "$N-dist" >/dev/null 2>&1; rm -rf "$W"; }
trap cleanup EXIT
P="$W/client"

# --- 骨架 ---
tf "new-pixi 缺 --design" bash "$K/scripts/new-pixi.sh" "$W/x" --no-install
tf "new-pixi --design 格式錯" bash "$K/scripts/new-pixi.sh" "$W/x" --design 1920 --no-install
mkdir -p "$W/full" && touch "$W/full/a"
tf "new-pixi 目錄已有檔案" bash "$K/scripts/new-pixi.sh" "$W/full" --design 1920x1080 --no-install
t  "new-pixi 建骨架 + npm ci(--net ws --iframe)" bash "$K/scripts/new-pixi.sh" "$P" --design 1920x1080 --title "Self Test" --net ws --iframe
tf "--check:budgets 未填時失敗" bash "$K/scripts/new-pixi.sh" --check "$P"
sed -i '' -e 's/__FCP__/3000/;s/__INTERACTIVE__/15000/;s/__TBT__/1000/;s/__SCENE__/5000/;s/__BOOT__/400/;s/__ROUNDS__/5/;s/__HEAP__/50/;s/__NODES__/20/;s/__LISTENERS__/10/;s/__OBJECTS__/0/' "$P/docs/performance-budgets.md"
t  "--check:填好後通過" bash "$K/scripts/new-pixi.sh" --check "$P"
t  "design.ts 寫入 1920×1080" grep -q 'width: 1920, height: 1080' "$P/src/config/design.ts"
t  "--net ws / --iframe 模組已加入" test -f "$P/src/services/net/WsTransport.ts" -a -f "$P/src/services/iframe/bridge.ts"
t  "lockfile 鎖 pixi 8.23.0" node -e "process.exit(require('$P/package-lock.json').packages['node_modules/pixi.js'].version==='8.23.0'?0:1)"

cd "$P" || exit 1
# --- 指令 ---
t "typecheck" npm run typecheck
t "vitest" npx --no vitest run
t "build" npm run build

# --- 檢查腳本 ---
t  "check-layers 通過" node "$K/scripts/check-layers.mjs" "$P"
t  "check-i18n 通過" node "$K/scripts/check-i18n.mjs" "$P"
t  "check-assets 通過" node "$K/scripts/check-assets.mjs" "$P"
t  "check-early 通過" node "$K/scripts/check-early.mjs" "$P"
echo "import { Sprite } from 'pixi.js'; export const s = Sprite;" > "$P/src/game/bad.ts"
tf "check-layers 抓到 src/game import pixi" node "$K/scripts/check-layers.mjs" "$P"
tf "vitest no-pixi 測試也擋" npx --no vitest run src/game/no-pixi.test.ts
rm "$P/src/game/bad.ts"
r=$(node "$K/scripts/check-i18n.mjs" "$K/tests/fixtures/i18n-bad"); n=$(echo "$r" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).violations.length)")
[ "$n" = 8 ] && ok "check-i18n 漏報案例全抓到(8)" || bad "check-i18n 漏報案例" "$r"
t  "check-i18n 誤報案例全部放行" node "$K/scripts/check-i18n.mjs" "$K/tests/fixtures/i18n-good"
# 首屏洩漏:main.ts 靜態 import play 群組的圖
node -e "
const sharp=require('$P/node_modules/sharp');sharp({create:{width:8,height:8,channels:4,background:'#f00'}}).png().toFile('$P/src/assets/play/leak@1x.png')" 
cp "$P/src/main.ts" "$W/main.bak"; printf "import leak from './assets/play/leak@1x.png?url';\nconsole.debug(leak);\n" | cat - "$W/main.bak" > "$P/src/main.ts"
npm run build >/dev/null 2>&1
tf "check-early 抓到首屏漏進 play 素材" node "$K/scripts/check-early.mjs" "$P"
tf "check-assets 抓到孤兒檔" node "$K/scripts/check-assets.mjs" "$P"
cp "$W/main.bak" "$P/src/main.ts"; rm "$P/src/assets/play/leak@1x.png"; npm run build >/dev/null 2>&1

# --- 素材管線(假的 art/assets:sprite density 2、frames、不透明背景、音效) ---
A="$W/art/assets"; mkdir -p "$A/play" "$A/title"
node -e "
const sharp=require('$P/node_modules/sharp');
(async()=>{
await sharp({create:{width:240,height:320,channels:4,background:{r:0,g:0,b:0,alpha:0}}}).composite([{input:Buffer.from('<svg width=\"240\" height=\"320\"><circle cx=\"120\" cy=\"200\" r=\"100\" fill=\"#3a6\"/></svg>')}]).png().toFile('$A/play/hero.idle.png');
await sharp({create:{width:480,height:160,channels:4,background:{r:255,g:200,b:0,alpha:1}}}).png().toFile('$A/play/hero.run.png');
await sharp({create:{width:2048,height:1152,channels:3,background:'#246'}}).png().toFile('$A/title/bg.title.png');
})()"
printf 'OggS-fake' > "$A/play/sfx.hit.ogg"; printf 'm4a-fake' > "$A/play/sfx.hit.m4a"
cat > "$A/assets.json" <<'JSON'
{"version":1,"assets":[
 {"id":"hero.idle","type":"sprite","group":"play","files":["play/hero.idle.png"],"width":120,"height":160,"density":2,"anchor":[0.5,1],"character":"hero","source":"out/x/manifest.json#hero.idle.png","review":"pending"},
 {"id":"hero.run","type":"frames","group":"play","files":["play/hero.run.png"],"width":80,"height":80,"density":2,"anchor":[0.5,1],"frames":{"count":3,"fps":10,"frameWidth":160,"frameHeight":160,"columns":3},"source":"out/x/manifest.json#hero.run.png","review":"pending"},
 {"id":"bg.title","type":"background","group":"title","files":["title/bg.title.png"],"width":1920,"height":1080,"density":1.0666666666666667,"anchor":[0,0],"opaque":true,"source":"out/x/manifest.json#bg.title.png","review":"pending"},
 {"id":"sfx.hit","type":"sfx","group":"play","files":["play/sfx.hit.ogg","play/sfx.hit.m4a"],"durationSec":0.5,"lufs":-16,"source":"out/x/manifest.json#sfx.hit.ogg","review":"pending"}
]}
JSON
python3 - docs/performance-budgets.md <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("| group | 1x_kb | 0.5x_kb |\n|---|---|---|\n", "| group | 1x_kb | 0.5x_kb |\n|---|---|---|\n| play | 100 | 50 |\n| title | 300 | 100 |\n", 1)
open(p, "w").write(s)
PY
t  "預算表寫入" grep -q '^| title | 300 | 100 |$' docs/performance-budgets.md
t  "build-assets 產生 1x / 0.5x 與 manifest" node scripts/build-assets.mjs --src "$A"
t  "產出:sprite AVIF + PNG 兩級、背景 JPG、音效複製" test -f src/assets/play/hero.idle@1x.avif -a -f src/assets/play/hero.idle@0.5x.png -a -f src/assets/title/bg.title@1x.jpg -a -f src/assets/play/sfx.hit.ogg
t  "0.5x 尺寸 = 一半(進位成偶數)" node -e "const s=require('sharp');s('src/assets/play/hero.idle@0.5x.png').metadata().then(m=>process.exit(m.width===120&&m.height===160?0:1))"
t  "manifest 記錄 frames 與顯示尺寸" node -e "const m=require('./src/assets/play/manifest.json');const r=m.assets['hero.run'];process.exit(r.frames.columns===3&&r.width===80&&m.assets['sfx.hit'].files.m4a?0:1)"
t  "check-assets 通過(含 --art)" node "$K/scripts/check-assets.mjs" "$P" --art "$A"
t  "接上素材後 build 與 check-early 仍通過" bash -c "npm run build >/dev/null 2>&1 && node '$K/scripts/check-early.mjs' '$P'"
sed -i '' 's/^| title | 300 | 100 |$/| title | 0.1 | 100 |/' docs/performance-budgets.md
tf "build-assets 超過 KB 預算就失敗" node scripts/build-assets.mjs --src "$A"
tf "check-assets 超過 KB 預算就失敗" node "$K/scripts/check-assets.mjs" "$P"
sed -i '' 's/^| title | 0.1 | 100 |$/| title | 300 | 100 |/' docs/performance-budgets.md
node -e "const f='$A/assets.json';const d=JSON.parse(require('fs').readFileSync(f));d.assets[0].width=121;require('fs').writeFileSync('$W/bad.json',JSON.stringify(d))"; cp "$A/assets.json" "$W/good.json"; cp "$W/bad.json" "$A/assets.json"
tf "build-assets 1x 尺寸不等於顯示 × density 就失敗" node scripts/build-assets.mjs --src "$A"
cp "$W/good.json" "$A/assets.json"; node scripts/build-assets.mjs --src "$A" >/dev/null

# --- E2E(dev server,全尺寸) ---
out=$(bash "$WK/serve.sh" "$N-dev" "$P" 5173 -- npm run dev 2>&1); PORT_DEV=$(echo "$out" | sed -n 's/.*port=\([0-9]*\).*/\1/p')
if [ -n "$PORT_DEV" ]; then
  t "E2E 全尺寸(DEMO-S1/S3/S4/S5)" env PORT="$PORT_DEV" SHOTS_DIR="$W/shots" E2E_OUTPUT_DIR="$W/e2e-out" npx --no playwright test
  t "截圖 7 張寫在暫存" test "$(ls "$W/shots" | wc -l | tr -d ' ')" = 7
else bad "啟動 dev server" "$out"; fi
bash "$WK/stop.sh" "$N-dev" >/dev/null 2>&1

# --- perf(production build + gzip,各 1 次)與 Worker 限速 ---
npx --no vite build --outDir "$W/dist" >/dev/null 2>&1
head -c 368640 /dev/urandom > "$W/dist/blob.bin"
out=$(bash "$WK/serve.sh" "$N-dist" "$P" 4175 -- node scripts/serve-dist.mjs "$W/dist" 2>&1); PORT_DIST=$(echo "$out" | sed -n 's/.*port=\([0-9]*\).*/\1/p')
if [ -n "$PORT_DIST" ]; then
  t "serve-dist gzip 壓縮 JS" bash -c "curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w '%header{content-encoding}' http://127.0.0.1:$PORT_DIST/index.html | grep -q gzip"
  cat > tests/perf/zz-worker.perf.spec.ts <<'TS'
import { expect, test } from '@playwright/test';
import { newPage, throttle } from './lib';
test('worker fetch is throttled', async ({ browser }) => {
  const page = await newPage(browser, 'desktop');
  await page.goto('/');
  await throttle(page, 1);
  const ms = await page.evaluate(() => new Promise<number>((res) => {
    const src = "onmessage = async (e) => { const t0 = performance.now(); await (await fetch(e.data + '/blob.bin?' + Math.random())).arrayBuffer(); postMessage(performance.now() - t0); };";
    const w = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
    w.onmessage = (e) => res(e.data); w.postMessage(location.origin);
  }));
  console.log('worker-fetch-ms', ms);
  expect(ms).toBeGreaterThan(2000);
});
TS
  t "Worker 內 fetch 360 KB 在 Slow 4G 下 > 2 秒" env PORT="$PORT_DIST" PERF_OUTPUT_DIR="$W/perf-out" npx --no playwright test -c tests/perf/playwright.perf.config.ts zz-worker
  rm tests/perf/zz-worker.perf.spec.ts
  t "perf 首屏 / 場景切換 / soak(各 1 次,desktop)" env PORT="$PORT_DIST" PERF_RUNS=1 PERF_VIEW=desktop PERF_RESULTS_DIR="$W/perf" PERF_OUTPUT_DIR="$W/perf-out" npx --no playwright test -c tests/perf/playwright.perf.config.ts
  t "perf 首屏(phone 844×390@3x)" env PORT="$PORT_DIST" PERF_RUNS=1 PERF_VIEW=phone PERF_RESULTS_DIR="$W/perf" PERF_OUTPUT_DIR="$W/perf-out" npx --no playwright test -c tests/perf/playwright.perf.config.ts first-screen
  t "perf 結果寫進 jsonl" test "$(wc -l < "$W/perf/perf.jsonl" | tr -d ' ')" = 4
else bad "啟動 serve-dist" "$out"; fi
bash "$WK/stop.sh" "$N-dist" >/dev/null 2>&1

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
