#!/bin/bash
# stack-pixi 自我測試:建骨架 → npm ci → tsc / vitest / build(輸出到暫存)/ 四個檢查(含故意違規、--baseline、layout absent、用法錯誤)/
#   素材管線 / E2E 全尺寸 / perf 一次(soak 經 serve.sh + bg-job.mjs)/ Worker 限速。
# 需要網路(npm registry)、本機 Google Chrome、同層的 game-art-kit 與 web-dev-kit。測完刪除暫存、停止服務。
set -uo pipefail
K="$(cd "$(dirname "$0")/.." && pwd)"
WK="$K/../web-dev-kit/scripts"
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | tail -20 | sed 's/^/      /'; FAIL=$((FAIL + 1)); }
t()   { local name=$1; shift; local out; if out=$("$@" 2>&1); then ok "$name"; else bad "$name" "$out"; fi; }
tf()  { local name=$1; shift; local out; if out=$("$@" 2>&1); then bad "$name(應失敗)" "$out"; else ok "$name"; fi; }
# tc <結束碼> <名稱> <指令...>:結束碼必須剛好等於指定值
tc()  { local want=$1 name=$2; shift 2; local out rc; out=$("$@" 2>&1); rc=$?; if [ "$rc" = "$want" ]; then ok "$name"; else bad "$name(結束碼 $rc,應為 $want)" "$out"; fi; }
# jget <json> <js 運算式(變數 j)>
jget() { echo "$1" | node -e "const j=JSON.parse(require('fs').readFileSync(0,'utf8'));console.log($2)"; }
# 跨平台取代(BSD / GNU sed 的 -i 不相容):repl <檔案> <舊> <新> [<舊> <新>]...
repl() { node -e 'const fs=require("fs");const [f,...p]=process.argv.slice(1);let s=fs.readFileSync(f,"utf8");for(let i=0;i<p.length;i+=2)s=s.split(p[i]).join(p[i+1]);fs.writeFileSync(f,s)' "$@"; }
W="$(mktemp -d)"; N="sptest$$"
export WEB_DEV_KIT_TMP="$W/web-dev-kit"   # serve.sh / stop.sh 的狀態目錄放在暫存裡,測完一起刪
cleanup() { for s in dev dist soak; do bash "$WK/stop.sh" "$N-$s" >/dev/null 2>&1; done; rm -rf "$W"; }
trap cleanup EXIT
P="$W/client"

# --- 骨架 ---
tf "new-pixi 缺 --design" bash "$K/scripts/new-pixi.sh" "$W/x" --no-install
tf "new-pixi --design 格式錯" bash "$K/scripts/new-pixi.sh" "$W/x" --design 1920 --no-install
tf "new-pixi --design 0 開頭(0800x0600)" bash "$K/scripts/new-pixi.sh" "$W/x" --design 0800x0600 --no-install
t  "new-pixi --help 印用法、結束碼 0" bash -c "bash '$K/scripts/new-pixi.sh' --help | grep -q -- '--design'"
t  "new-pixi --help 不建立名為 --help 的目錄" test ! -e "$W/--help" -a ! -e ./--help
mkdir -p "$W/withgit" && git -C "$W/withgit" init -q
t  "new-pixi 目錄只有 .git 時可以建骨架" bash -c "bash '$K/scripts/new-pixi.sh' '$W/withgit' --design 1280x720 --no-install >/dev/null 2>&1 && test -f '$W/withgit/src/main.ts' -a -d '$W/withgit/.git'"
rm -rf "$W/withgit"
mkdir -p "$W/full" && touch "$W/full/a"
tf "new-pixi 目錄已有檔案" bash "$K/scripts/new-pixi.sh" "$W/full" --design 1920x1080 --no-install
t  "new-pixi 建骨架 + npm ci(--net ws --iframe)" bash "$K/scripts/new-pixi.sh" "$P" --design 1920x1080 --title "Self Test" --net ws --iframe
tf "--check:budgets 未填時失敗" bash "$K/scripts/new-pixi.sh" --check "$P"
repl "$P/docs/performance-budgets.md" __FCP__ 3000 __INTERACTIVE__ 15000 __TBT__ 1000 __SCENE__ 5000 __BOOT__ 400 __ROUNDS__ 5 __HEAP__ 50 __NODES__ 20 __LISTENERS__ 10 __OBJECTS__ 0
t  "--check:填好後通過" bash "$K/scripts/new-pixi.sh" --check "$P"
printf '| interactive_ms | 1 |\n' >> "$P/docs/performance-budgets.md"   # 「最新實測」節的數字不可蓋掉門檻
t  "--check:相對路徑也可以" bash -c "cd '$W' && bash '$K/scripts/new-pixi.sh' --check client"
t  "design.ts 寫入 1920×1080" grep -q 'width: 1920, height: 1080' "$P/src/config/design.ts"
t  "--net ws / --iframe 模組已加入" test -f "$P/src/services/net/WsTransport.ts" -a -f "$P/src/services/iframe/bridge.ts"
t  "lockfile 鎖 pixi 8.23.0" node -e "process.exit(require('$P/package-lock.json').packages['node_modules/pixi.js'].version==='8.23.0'?0:1)"

cd "$P" || exit 1
# --- 指令 ---
t "typecheck" npm run typecheck
t "vitest" npx --no vitest run
t "build 輸出到暫存(--outDir),專案內沒有 dist/" bash -c "npm run build -- --outDir '$W/dist-check' --emptyOutDir >/dev/null 2>&1 && test -f '$W/dist-check/.vite/manifest.json' && test ! -e dist"
D="$W/dist-check"

# --- 檢查腳本 ---
t  "check-layers 通過" node "$K/scripts/check-layers.mjs" "$P"
t  "check-i18n 通過" node "$K/scripts/check-i18n.mjs" "$P"
t  "check-assets 通過" node "$K/scripts/check-assets.mjs" "$P"
t  "check-early 通過(--dist 暫存)" node "$K/scripts/check-early.mjs" "$P" --dist "$D"
# 用法錯誤(選項放最後、沒有值)→ 結束碼 2,不是丟例外
tc 2 "check-i18n --src 缺值" node "$K/scripts/check-i18n.mjs" "$P" --src
tc 2 "check-layers --paths 缺值" node "$K/scripts/check-layers.mjs" "$P" --paths
tc 2 "check-early --dist 缺值" node "$K/scripts/check-early.mjs" "$P" --dist
tc 2 "check-assets --baseline 缺值" node "$K/scripts/check-assets.mjs" "$P" --baseline
tc 2 "build-assets --src 缺值" node scripts/build-assets.mjs --src
tc 2 "build-assets --budgets 缺值" node scripts/build-assets.mjs --budgets
tc 2 "check-early --dist 目錄不存在(還沒建置)" node "$K/scripts/check-early.mjs" "$P" --dist "$W/nope"
# 不是 stack-pixi 結構(既有專案)→ 結束碼 3 "layout":"absent",和違規(1)分開
X="$W/legacy"; mkdir -p "$X/dist" "$X/src/assets/panel"; printf 'x' > "$X/src/assets/panel/a@1x.png"
tc 3 "check-early:vite 沒開 build.manifest → layout absent" node "$K/scripts/check-early.mjs" "$X" --dist "$X/dist"
mkdir -p "$X/dist/.vite" && echo '{}' > "$X/dist/.vite/manifest.json"
tc 3 "check-early:沒有 src/assets/early.ts 也沒給 --boot → layout absent" node "$K/scripts/check-early.mjs" "$X" --dist "$X/dist"
t  "check-early:給 --boot 就照常檢查" node "$K/scripts/check-early.mjs" "$X" --dist "$X/dist" --boot login
tc 3 "check-assets:沒有任何 <group>/manifest.json → layout absent" node "$K/scripts/check-assets.mjs" "$X"
r=$(node "$K/scripts/check-assets.mjs" "$X"); [ "$(jget "$r" 'j.layout')" = absent ] && ok "check-assets layout absent 印 layout: absent" || bad "check-assets layout 欄位" "$r"
rm -rf "$X"
echo "import { Sprite } from 'pixi.js'; export const s = Sprite;" > "$P/src/game/bad.ts"
tf "check-layers 抓到 src/game import pixi" node "$K/scripts/check-layers.mjs" "$P"
echo "import { Rectangle } from 'pixi.js/math-extras'; export const r = Rectangle;" > "$P/src/game/bad.ts"
tf "check-layers 抓到 pixi.js 子路徑" node "$K/scripts/check-layers.mjs" "$P"
printf "export const f = () => import(\n  'pixi.js'\n);\n" > "$P/src/game/bad.ts"
tf "check-layers 抓到跨行的 dynamic import" node "$K/scripts/check-layers.mjs" "$P"
echo "import { Rectangle } from 'pixi.js/math-extras'; export const r = Rectangle;" > "$P/src/game/bad.ts"
tf "vitest no-pixi 測試也擋" npx --no vitest run src/game/no-pixi.test.ts
printf "// never do: import { Sprite } from 'pixi.js'\nexport const ok = 1;\n" > "$P/src/game/bad.ts"
t  "check-layers 不把註解裡的 import 當違規" node "$K/scripts/check-layers.mjs" "$P"
printf "import { a } from './a';\n// CSP: no unsafe-eval at runtime\nimport 'pixi.js/unsafe-eval';\nexport const x = a;\n" > "$P/src/game/bad.ts"
r=$(node "$K/scripts/check-layers.mjs" "$P"); [ "$(jget "$r" 'j.violations.map(v=>v.line).join()')" = 3 ] && ok "check-layers 行號是 import 那一行(註解在上一行時)" || bad "check-layers 行號" "$r"
node "$K/scripts/check-layers.mjs" "$P" > "$W/layers-base.json"
tc 0 "check-layers --baseline:基準已有的不算失敗" node "$K/scripts/check-layers.mjs" "$P" --baseline "$W/layers-base.json"
printf '\n\n' | cat - "$P/src/game/bad.ts" > "$W/shift.ts" && mv "$W/shift.ts" "$P/src/game/bad.ts"
tc 0 "check-layers --baseline:行號移動不算新增" node "$K/scripts/check-layers.mjs" "$P" --baseline "$W/layers-base.json"
echo "import { Sprite } from 'pixi.js'; export const s = Sprite;" > "$P/src/game/bad2.ts"
r=$(node "$K/scripts/check-layers.mjs" "$P" --baseline "$W/layers-base.json"); rc=$?
[ $rc = 1 ] && [ "$(jget "$r" 'j.violations.length + "/" + j.existing.length')" = 1/1 ] && ok "check-layers --baseline:只有新增的算違規(1 新 / 1 既有)" || bad "check-layers --baseline 新增" "$r"
rm "$P/src/game/bad.ts" "$P/src/game/bad2.ts"
r=$(node "$K/scripts/check-i18n.mjs" "$K/tests/fixtures/i18n-bad"); n=$(echo "$r" | node -e "console.log(JSON.parse(require('fs').readFileSync(0,'utf8')).violations.length)")
[ "$n" = 15 ] && ok "check-i18n 漏報案例全抓到(15)" || bad "check-i18n 漏報案例" "$r"
t  "check-i18n 誤報案例全部放行(含 .tsx 的 </b>)" node "$K/scripts/check-i18n.mjs" "$K/tests/fixtures/i18n-good"
# --baseline:既有違規不擋 PASS;比對用 檔案 + 正規化文字,不看行號
cp -R "$K/tests/fixtures/i18n-bad" "$W/i18n"; node "$K/scripts/check-i18n.mjs" "$W/i18n" > "$W/i18n-base.json"
tc 0 "check-i18n --baseline:基準已有的 15 筆不算失敗" node "$K/scripts/check-i18n.mjs" "$W/i18n" --baseline "$W/i18n-base.json"
B="$W/i18n/src/scenes/Bad.ts"; { printf '\n\n\n'; cat "$B"; printf "label.text = 'Brand new text';\n"; } > "$W/b.ts" && mv "$W/b.ts" "$B"
r=$(node "$K/scripts/check-i18n.mjs" "$W/i18n" --baseline "$W/i18n-base.json"); rc=$?
[ $rc = 1 ] && [ "$(jget "$r" 'j.violations.length + "/" + j.existing.length + "/" + j.violations[0].text')" = "1/15/label.text = 'Brand new text';" ] && ok "check-i18n --baseline:行號全部移動後只抓到新增的 1 筆" || bad "check-i18n --baseline" "$r"
printf "label.text = \"Game over\";\n" >> "$B"
r=$(node "$K/scripts/check-i18n.mjs" "$W/i18n" --baseline "$W/i18n-base.json"); [ "$(jget "$r" 'j.violations.length')" = 2 ] && ok "check-i18n --baseline:同一段文字多出一次也算新增" || bad "check-i18n --baseline 重複" "$r"
tc 2 "check-i18n --baseline 檔案不存在 → 用法錯誤" node "$K/scripts/check-i18n.mjs" "$W/i18n" --baseline "$W/nope.json"
rm -rf "$W/i18n"
# 首屏洩漏:main.ts 靜態 import play 群組的圖
node -e "
const sharp=require('$P/node_modules/sharp');sharp({create:{width:8,height:8,channels:4,background:'#f00'}}).png().toFile('$P/src/assets/play/leak@1x.png')" 
cp "$P/src/main.ts" "$W/main.bak"; printf "import leak from './assets/play/leak@1x.png?url';\nconsole.debug(leak);\n" | cat - "$W/main.bak" > "$P/src/main.ts"
npm run build -- --outDir "$D" --emptyOutDir >/dev/null 2>&1
tc 1 "check-early 抓到首屏漏進 play 素材" node "$K/scripts/check-early.mjs" "$P" --dist "$D"
node "$K/scripts/check-early.mjs" "$P" --dist "$D" > "$W/early-base.json"
tc 0 "check-early --baseline:基準已有的不算失敗" node "$K/scripts/check-early.mjs" "$P" --dist "$D" --baseline "$W/early-base.json"
tc 1 "check-assets 抓到孤兒檔" node "$K/scripts/check-assets.mjs" "$P"
node "$K/scripts/check-assets.mjs" "$P" > "$W/assets-base.json"
tc 0 "check-assets --baseline:基準已有的不算失敗" node "$K/scripts/check-assets.mjs" "$P" --baseline "$W/assets-base.json"
cp "$W/main.bak" "$P/src/main.ts"; rm "$P/src/assets/play/leak@1x.png"; npm run build -- --outDir "$D" --emptyOutDir >/dev/null 2>&1

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
printf 'OggS-fake' > "$A/play/sfx.tick.ogg"; printf 'm4a-fake' > "$A/play/sfx.tick.m4a"
cat > "$A/assets.json" <<'JSON'
{"version":1,"assets":[
 {"id":"hero.idle","type":"sprite","group":"play","files":["play/hero.idle.png"],"width":120,"height":160,"density":2,"anchor":[0.5,1],"character":"hero","source":"out/x/manifest.json#hero.idle.png","review":"pending"},
 {"id":"hero.run","type":"frames","group":"play","files":["play/hero.run.png"],"width":80,"height":80,"density":2,"anchor":[0.5,1],"frames":{"count":3,"fps":10,"frameWidth":160,"frameHeight":160,"columns":3},"source":"out/x/manifest.json#hero.run.png","review":"pending"},
 {"id":"bg.title","type":"background","group":"title","files":["title/bg.title.png"],"width":1920,"height":1080,"density":1.0666666666666667,"anchor":[0,0],"opaque":true,"source":"out/x/manifest.json#bg.title.png","review":"pending"},
 {"id":"sfx.hit","type":"sfx","group":"play","files":["play/sfx.hit.ogg","play/sfx.hit.m4a"],"durationSec":0.5,"lufs":-16,"source":"out/x/manifest.json#sfx.hit.ogg","review":"pending"},
 {"id":"sfx.tick","type":"sfx","group":"play","files":["play/sfx.tick.ogg","play/sfx.tick.m4a"],"durationSec":0.2,"normalized":"peak","source":"out/x/manifest.json#sfx.tick.ogg","review":"pending"}
]}
JSON
python3 - docs/performance-budgets.md <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
s = s.replace("| group | 1x_kb | 0.5x_kb |\n|---|---|---|\n", "| group | 1x_kb | 0.5x_kb |\n|---|---|---|\n| play | 100 | 50 |\n| title | 300 | 100 |\n", 1)
open(p, "w").write(s)
PY
t  "預算表寫入" grep -q '^| title | 300 | 100 |$' docs/performance-budgets.md
printf '{"group":"boot","assets":{"logo":{"type":"sprite","files":{"1x.avif":"logo@1x.avif"}}}}\n' > src/assets/boot/manifest.json; printf 'x' > src/assets/boot/logo@1x.avif
t  "build-assets 產生 1x / 0.5x 與 manifest" node scripts/build-assets.mjs --src "$A"
t  "手寫的 boot 群組不被動到" test -f src/assets/boot/logo@1x.avif
t  "產出:sprite AVIF + PNG 兩級、背景 JPG、音效複製" test -f src/assets/play/hero.idle@1x.avif -a -f src/assets/play/hero.idle@0.5x.png -a -f src/assets/title/bg.title@1x.jpg -a -f src/assets/play/sfx.hit.ogg
t  "0.5x 尺寸 = 一半(進位成偶數)" node -e "const s=require('sharp');s('src/assets/play/hero.idle@0.5x.png').metadata().then(m=>process.exit(m.width===120&&m.height===160?0:1))"
t  "frames 的 0.5x sheet 剛好一半(480→240)" node -e "const s=require('sharp');s('src/assets/play/hero.run@0.5x.png').metadata().then(m=>process.exit(m.width===240&&m.height===80?0:1))"
t  "短音效 normalized: peak(沒有 lufs)也接受" test -f src/assets/play/sfx.tick.ogg -a -f src/assets/play/sfx.tick.m4a
t  "manifest 記錄 frames 與顯示尺寸" node -e "const m=require('./src/assets/play/manifest.json');const r=m.assets['hero.run'];process.exit(r.frames.columns===3&&r.width===80&&m.assets['sfx.hit'].files.m4a?0:1)"
t  "check-assets 通過(含 --art)" node "$K/scripts/check-assets.mjs" "$P" --art "$A"
t  "接上素材後 build 與 check-early 仍通過" bash -c "npm run build -- --outDir '$D' --emptyOutDir >/dev/null 2>&1 && node '$K/scripts/check-early.mjs' '$P' --dist '$D'"
repl docs/performance-budgets.md '| title | 300 | 100 |' '| title | 0.1 | 100 |'
tf "build-assets 超過 KB 預算就失敗" node scripts/build-assets.mjs --src "$A"
t  "超過預算時既有產出不變(title 仍是舊的 manifest)" grep -q bg.title src/assets/title/manifest.json
tf "check-assets 超過 KB 預算就失敗" node "$K/scripts/check-assets.mjs" "$P"
repl docs/performance-budgets.md '| title | 0.1 | 100 |' '| title | 300 | 100 |'
node -e "const f='$A/assets.json';const d=JSON.parse(require('fs').readFileSync(f));d.assets[0].width=121;require('fs').writeFileSync('$W/bad.json',JSON.stringify(d))"; cp "$A/assets.json" "$W/good.json"; cp "$W/bad.json" "$A/assets.json"
tf "build-assets 1x 尺寸不等於顯示 × density 就失敗" node scripts/build-assets.mjs --src "$A"
t  "失敗時既有產出不動(manifest 與 hero.idle 還在)" test -f src/assets/play/manifest.json -a -f src/assets/play/hero.idle@1x.avif
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
  t "serve-dist 壞掉的網址回 400 且伺服器還活著" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' 'http://127.0.0.1:$PORT_DIST/%E0%A4%A')\" = 400 ] && curl -sf -o /dev/null http://127.0.0.1:$PORT_DIST/index.html"
  t "serve-dist 擋住 dist 以外的路徑" bash -c "[ \"\$(curl -s -o /dev/null -w '%{http_code}' --path-as-is 'http://127.0.0.1:$PORT_DIST/..%2F..%2Fetc%2Fhosts')\" != 200 ]"
  JS=$(cd "$W/dist" && ls assets/*.js | head -1)
  t "serve-dist gzip 壓縮 JS($JS)" bash -c "curl -s -H 'Accept-Encoding: gzip' -o /dev/null -w '%header{content-encoding}' http://127.0.0.1:$PORT_DIST/$JS | grep -q gzip"
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
  t "perf 首屏 / 場景切換(各 1 次,desktop)" env PORT="$PORT_DIST" PERF_RUNS=1 PERF_VIEW=desktop PERF_RESULTS_DIR="$W/perf" PERF_OUTPUT_DIR="$W/perf-out" npx --no playwright test -c tests/perf/playwright.perf.config.ts first-screen scene-switch
  # soak 照 agent 的做法:經 serve.sh + bg-job.mjs 在背景執行,輪詢狀態,stop.sh 收掉
  out=$(bash "$WK/serve.sh" "$N-soak" "$P" 4190 -- node "$K/scripts/bg-job.mjs" -- env PERF_BASE_URL="http://127.0.0.1:$PORT_DIST" PERF_RUNS=1 PERF_VIEW=desktop PERF_RESULTS_DIR="$W/perf" PERF_OUTPUT_DIR="$W/perf-out" node_modules/.bin/playwright test -c tests/perf/playwright.perf.config.ts soak 2>&1)
  PORT_SOAK=$(echo "$out" | sed -n 's/.*port=\([0-9]*\).*/\1/p'); st=""
  if [ -n "$PORT_SOAK" ]; then
    for _ in $(seq 1 300); do st=$(curl -s "http://127.0.0.1:$PORT_SOAK/"); echo "$st" | grep -q '"state":"done"' && break; sleep 1; done
    [ "$(jget "$st" 'j.state + ":" + j.code')" = "done:0" ] && ok "soak 經 serve.sh + bg-job 背景執行並結束碼 0" || bad "soak(bg-job)" "$st $(tail -20 "$WEB_DEV_KIT_TMP/$N-soak/server.log")"
  else bad "啟動 bg-job" "$out"; fi
  bash "$WK/stop.sh" "$N-soak" >/dev/null 2>&1
  t "bg-job 已停止(埠釋放)" bash -c "! lsof -nP -iTCP:${PORT_SOAK:-1} -sTCP:LISTEN -t >/dev/null 2>&1"
  t "perf 首屏(phone 844×390@3x)" env PORT="$PORT_DIST" PERF_RUNS=1 PERF_VIEW=phone PERF_RESULTS_DIR="$W/perf" PERF_OUTPUT_DIR="$W/perf-out" npx --no playwright test -c tests/perf/playwright.perf.config.ts first-screen
  t "perf 結果寫進 jsonl" test "$(wc -l < "$W/perf/perf.jsonl" | tr -d ' ')" = 4
else bad "啟動 serve-dist" "$out"; fi
bash "$WK/stop.sh" "$N-dist" >/dev/null 2>&1
t "專案內沒有建置 / E2E / perf 輸出(dist、test-results、perf results)" test ! -e "$P/dist" -a ! -e "$P/tests/e2e/test-results" -a ! -e "$P/tests/perf/results"

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
