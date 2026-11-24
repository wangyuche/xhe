#!/bin/bash
# motion-video-kit 自我測試。用法:bash tests/run.sh
# 用正弦波當假旁白跑 9 種場景(模板 sample.storyboard.json);tts.mjs 用 game-art-kit 的假 ComfyUI(與 macOS say,有 Meijia 時)測。
# 缺 Chrome / ffmpeg 印 SKIP 並以結束碼 3 結束(SKIP 不算通過)。結束時刪除所有暫存檔,不寫進 kit 的 preview/。
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/scripts"; SVK="$KIT/../short-video-kit/scripts"; GAK="$KIT/../game-art-kit"
TPL="$KIT/templates/github-hot-pastel"
export SHORT_VIDEO_KIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mvk-test-kit.XXXXXX")"
T="$(mktemp -d "${TMPDIR:-/tmp}/mvk-test.XXXXXX")"
FPID=""
cleanup() { [ -n "$FPID" ] && kill "$FPID" 2>/dev/null; rm -rf "$T" "$SHORT_VIDEO_KIT_TMP"; }
trap cleanup EXIT

PASS=0; FAIL=0; SKIP=0
ok() { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "$2" | tail -8 | sed 's/^/      /'; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
jget() { node -e 'const j=JSON.parse(process.argv[1]);const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],j);console.log(typeof v==="object"?JSON.stringify(v):v)' "$1" "$2"; }
R() { node "$S/render.mjs" "$@"; }

if ! command -v ffmpeg >/dev/null 2>&1 || [ ! -x "${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}" ]; then
  echo "SKIP  全部:缺 ffmpeg 或 Google Chrome(SKIP 不算通過)"; exit 3
fi
cd "$T"
mkfix() { node -e '
const fs=require("fs");const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const f=new Function("b",process.argv[3]);f(b);fs.writeFileSync(process.argv[2],JSON.stringify(b))' "$TPL/sample.storyboard.json" "$1" "$2"; }

# 1. check.mjs
o="$(node "$S/check.mjs")"; [ $? -eq 0 ] && [ "$(jget "$o" template.source)" = kit ] && [ "$(jget "$o" template.size)" = '[1080,1440]' ] && ok "check.mjs:預設模板 github-hot-pastel(kit)、工具齊全" || bad "check.mjs 預設" "$o"
cp -R "$TPL" tplcopy; rm -rf tplcopy/preview/*
mkdir -p job/_templates && cp -R tplcopy job/_templates/mine
o="$(node "$S/check.mjs" --template mine --out job)"; [ $? -eq 0 ] && [ "$(jget "$o" template.source)" = project ] && ok "check.mjs:專案模板 <out>/_templates/<名稱> 優先於 kit" || bad "check.mjs 專案模板" "$o"
o="$(node "$S/check.mjs" --template nosuch 2>&1)"; [ $? -eq 3 ] && ok "check.mjs:模板找不到 → 結束碼 3" || bad "check.mjs 找不到" "$o"
cp -R tplcopy badtpl && node -e 'const f="badtpl/template.json";const j=JSON.parse(require("fs").readFileSync(f));delete j.safe;j.mascot.happy="assets/nope.png";require("fs").writeFileSync(f,JSON.stringify(j))'
o="$(node "$S/check.mjs" --template-dir badtpl 2>&1)"; [ $? -eq 3 ] && echo "$o" | grep -q 'safe' && echo "$o" | grep -q 'mascot.happy' && ok "check.mjs:缺必填欄位 / 姿勢檔不存在 → 結束碼 3 並列出" || bad "check.mjs 不合格模板" "$o"

# 2. --sample(寫到模板副本的 preview/)
o="$(R --sample --template-dir tplcopy 2>&1)"; rc=$?
n="$(ls tplcopy/preview/scene-*.png 2>/dev/null | wc -l | tr -d ' ')"
[ $rc -eq 0 ] && [ "$n" = 9 ] && [ -f tplcopy/preview/contact.png ] && [ "$(ffprobe -v error -show_entries stream=width,height -of csv=s=x:p=0 tplcopy/preview/scene-01.png)" = 1080x1440 ] \
  && ok "render.mjs --sample:9 張 scene-NN.png(1080×1440)+ contact.png" || bad "--sample" "$o"
[ "$(jget "$(echo "$o" | tail -1)" rhythm.ok)" = true ] && ok "範例 storyboard 的 rhythm.ok = true" || bad "範例 rhythm" "$o"

# 3. 9 種場景完整渲染 + 混音 + verify.sh(--size、--safe-json)
node "$KIT/tests/fake-tts.mjs" "$TPL/sample.storyboard.json" s1/tts >/dev/null
t0=$(date +%s)
o="$(R "$TPL/sample.storyboard.json" s1/tts/tts.json s1/work --deliver s1/out --asset-root "$TPL/sample" 2>s1.err)"; rc=$?
[ $rc -eq 0 ] && for f in work/silent.mp4 work/boxes.json work/safe.json work/timing.json work/scenes.json out/subtitles.srt out/cover.png; do [ -f "s1/$f" ] || rc=99; done
[ $rc -eq 0 ] && ok "render.mjs:中間檔寫輸出目錄、subtitles.srt / cover.png 寫 --deliver($(( $(date +%s) - t0 )) 秒)" || bad "render.mjs 9 種場景" "$o $(tail -3 s1.err)"
m="$(node "$S/mix.mjs" s1/work/silent.mp4 s1/tts/tts.json s1/work/timing.json s1/out/final.mp4 2>&1)"; [ $? -eq 0 ] && ok "mix.mjs:旁白排程 + loudnorm(共用 short-video-kit _mix.mjs)" || bad "mix.mjs" "$m"
v="$(bash "$SVK/verify.sh" s1/out/final.mp4 s1/out/checks --size 1080x1440 --safe-json s1/work/safe.json --boxes s1/work/boxes.json --cover s1/out/cover.png --scenes s1/work/scenes.json)"; rc=$?
[ $rc -eq 0 ] && [ "$(jget "$v" fps)" = 30 ] && [ "$(jget "$v" width)x$(jget "$v" height)" = 1080x1440 ] && ok "verify.sh --size 1080x1440 通過(尺寸 / 30 fps / h264 / aac 48k / faststart / 響度 / 安全區 / 封面 / 鏡頭表)" || bad "verify.sh" "$v"
node -e '
const fs=require("fs");const t=JSON.parse(fs.readFileSync("s1/work/timing.json","utf8"));const tts=JSON.parse(fs.readFileSync("s1/tts/tts.json","utf8"));
const sc=JSON.parse(fs.readFileSync("s1/work/scenes.json","utf8"));const v=Number(process.argv[1]);
let x=0,ok=true;tts.forEach((a,i)=>{const s=i?x+0.25:0.3,e=s+a.duration;if(Math.abs(t.sentences[i].start-s)>0.002||Math.abs(t.sentences[i].end-e)>0.002)ok=false;x=e});
ok=ok&&Math.abs(t.duration-(x+0.6))<0.002&&Math.abs(v-t.duration)<0.05;
ok=ok&&sc[0].start===0&&sc.every((s,i)=>i===0||s.start===sc[i-1].end)&&sc[sc.length-1].end===t.duration&&sc.length===9;
const keys=["duration","sentences","scenes","changes","cardEmpty","rhythm"];ok=ok&&keys.every(k=>k in t)&&["maxEmpty","minInterval","maxInterval","ok"].every(k=>k in t.rhythm);
ok=ok&&t.sentences[0].words.every(w=>"w" in w&&"start" in w&&"end" in w&&"hl" in w);
process.exit(ok?0:1)' "$(jget "$v" duration)" && ok "時間軸:句子 start/end = 公式、片長 = 末句 end + 0.6、scenes.json 從 0 首尾相接到片長、timing.json 欄位齊全" || bad "時間軸" "$(head -c 600 s1/work/timing.json)"
node -e '
const fs=require("fs");const t=JSON.parse(fs.readFileSync("s1/work/timing.json","utf8"));
const srt=fs.readFileSync("s1/out/subtitles.srt","utf8").trim().split(/\n\n/).map(b=>{const l=b.split("\n");const [a,z]=l[1].split(" --> ").map(x=>{const [h,m,s]=x.replace(",",".").split(":");return h*3600+m*60+Number(s)});return {a,z,text:l[2]}});
const b=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const want=b.scenes.flatMap(s=>s.lines).map(l=>(typeof l==="string"?l:l.text));
const strip=(x)=>{const w=[];x.split("*").forEach((p,i)=>{if(i%2)w.push(p.trim());else w.push(...p.split(/ +/).filter(Boolean))});return w.reduce((a,c)=>a+(a&&/[A-Za-z0-9]$/.test(a)&&/^[A-Za-z0-9]/.test(c)?" ":"")+c,"")};
const ok=srt.length===want.length&&srt.every((s,i)=>s.text===strip(want[i])&&!s.text.includes("*")&&Math.abs(s.a-t.sentences[i].start)<=0.05&&Math.abs(s.z-t.sentences[i].end)<=0.05);
process.exit(ok?0:1)' "$TPL/sample.storyboard.json" && ok "SRT:第 i 句 = text 去掉 * 與分段空白(英數詞間留一格)、時間 = 公式" || bad "SRT" "$(head -12 s1/out/subtitles.srt)"
grep -q '^去GitHub搜尋PixelForge$' s1/out/subtitles.srt && grep -q '^這個開源專案叫PixelForge$' s1/out/subtitles.srt && ok "SRT:「*開源專案*」顯示成「開源專案」、中英交界不加空白" || bad "SRT 顯示文字" "$(cat s1/out/subtitles.srt | head -20)"
node -e 'const t=JSON.parse(require("fs").readFileSync("s1/work/timing.json","utf8"));const w=t.sentences[1].words;process.exit(w.find(x=>x.w==="開源專案")?.hl===true&&w.find(x=>x.w==="這個")?.hl===false?0:1)' \
  && ok "timing.json:*關鍵詞* 標成 hl:true(膠囊)" || bad "關鍵詞 hl"
# 膠囊:第 2 句結束前一刻,字幕區要有大塊模板 accent 色(#EC5B2A)
te="$(node -e 'const t=JSON.parse(require("fs").readFileSync("s1/work/timing.json","utf8"));console.log((t.sentences[1].end-0.05).toFixed(3))')"
ffmpeg -hide_banner -loglevel error -y -ss "$te" -i s1/out/final.mp4 -frames:v 1 -vf "crop=984:228:48:1196,format=rgb24" -f rawvideo pill.raw
node -e 'const b=require("fs").readFileSync("pill.raw");let n=0;for(let i=0;i<b.length;i+=3)if(Math.abs(b[i]-236)<30&&Math.abs(b[i+1]-91)<35&&Math.abs(b[i+2]-42)<35)n++;process.exit(n>8000?0:1)' \
  && ok "畫面:關鍵詞畫成橘色膠囊(字幕區有 accent 色塊)" || bad "膠囊顏色"
node -e 'const b=JSON.parse(require("fs").readFileSync("s1/work/boxes.json","utf8"));process.exit(b.filter(x=>x.kind==="subtitle").length===11&&b.some(x=>x.kind==="headline")&&b.every(x=>x.file&&x.w>0&&x.h>0)?0:1)' \
  && ok "boxes.json:每筆有 kind(subtitle 11 句 + headline)" || bad "boxes.json" "$(head -c 300 s1/work/boxes.json)"
c="$(node "$S/contact.mjs" s1/out/final.mp4 s1/out/contact.png --every 1)"; [ $? -eq 0 ] && [ "$(jget "$c" frames)" -ge 30 ] && ok "contact.mjs:每秒一格總表($(jget "$c" frames) 格)" || bad "contact.mjs" "$c"

# 4. 可重現:同輸入渲染兩次,第 0、中、末格 PNG 雜湊相同
mkfix short.json 'b.scenes=b.scenes.slice(2,4)'
node "$KIT/tests/fake-tts.mjs" short.json sh/tts >/dev/null
R short.json sh/tts/tts.json sh/a --deliver sh/ad --asset-root "$TPL/sample" >/dev/null 2>&1 && R short.json sh/tts/tts.json sh/b --deliver sh/bd --asset-root "$TPL/sample" >/dev/null 2>&1
hashes() { local d n; d="$(ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of default=nw=1:nk=1 "$1")"; for n in 0 $((d / 2)) $((d - 1)); do ffmpeg -hide_banner -loglevel error -i "$1" -vf "select=eq(n\,$n)" -frames:v 1 -f image2pipe -c:v png - | shasum | cut -c1-12; done | tr '\n' ' '; }
h1="$(hashes sh/a/silent.mp4)"; h2="$(hashes sh/b/silent.mp4)"
[ -n "$h1" ] && [ "$h1" = "$h2" ] && [ "$(echo "$h1" | wc -w | tr -d ' ')" = 3 ] && ok "可重現:兩次渲染第 0 / 中 / 末格 PNG 雜湊相同($h1)" || bad "可重現" "$h1 / $h2"

# 5. 版面放不下 → 結束碼 4
mkfix longhl.json 'b.scenes=b.scenes.slice(0,2);b.scenes[1].headline=[["一二三四五六七八九十一二三四","五六七八九十一二三四五"]]'
node "$KIT/tests/fake-tts.mjs" longhl.json lh/tts >/dev/null
e="$(R longhl.json lh/tts/tts.json lh/w --deliver lh/d --asset-root "$TPL/sample" 2>&1)"; [ $? -eq 4 ] && echo "$e" | grep -q '大標放不下' && ok "大標縮到 minFont 仍放不下 → 結束碼 4" || bad "大標越界" "$e"
cp -R tplcopy widetpl && node -e 'const f="widetpl/template.json";const j=JSON.parse(require("fs").readFileSync(f));j.maxLineChars=80;require("fs").writeFileSync(f,JSON.stringify(j))'
mkfix longsub.json 'b.scenes=b.scenes.slice(0,1);b.scenes[0].lines=["這是一句非常非常長的字幕 這是一句非常非常長的字幕 這是一句非常非常長的字幕 這是一句非常非常長的字幕 這是一句長字幕"]'
node "$KIT/tests/fake-tts.mjs" longsub.json ls/tts >/dev/null
e="$(R longsub.json ls/tts/tts.json ls/w --deliver ls/d --template-dir widetpl 2>&1)"; [ $? -eq 4 ] && echo "$e" | grep -q '字幕放不下' && ok "字幕 2 行、縮到 minFont 仍放不下 → 結束碼 4" || bad "字幕越界" "$e"
mkfix midsub.json 'b.scenes=b.scenes.slice(0,1);b.scenes[0].lines=["這一句比較長一點 需要縮小字級才放得下喔"]'
node "$KIT/tests/fake-tts.mjs" midsub.json ms/tts >/dev/null
R midsub.json ms/tts/tts.json ms/w --deliver ms/d --template-dir widetpl >/dev/null 2>&1 && node -e 'const b=JSON.parse(require("fs").readFileSync("ms/w/boxes.json","utf8")).find(x=>x.kind==="subtitle");process.exit(b.fontSize<62&&b.x>=48&&b.x+b.w<=1032&&b.y>=1196&&b.y+b.h<=1424?0:1)' \
  && ok "字幕超寬時自動縮字,框在 safe.subtitle 內" || bad "字幕縮字" "$(cat ms/w/boxes.json 2>/dev/null | head -c 300)"

# 6. storyboard 錯誤 → 結束碼 2(並指出欄位)
mkdir -p big && ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=2000x1200 -frames:v 1 big/wide.png && cp "$TPL/sample/site.png" big/
node "$KIT/tests/fake-tts.mjs" "$TPL/sample.storyboard.json" e/tts >/dev/null
e2() { # 名稱 修改 期望訊息 [asset-root]
  mkfix "e-$1.json" "$2"
  local out; out="$(R "e-$1.json" e/tts/tts.json e/w --deliver e/d --asset-root "${4:-$TPL/sample}" 2>&1)"; local rc=$?
  [ $rc -eq 2 ] && echo "$out" | grep -q -- "$3" && ok "storyboard 錯誤($1)→ 結束碼 2:$3" || bad "storyboard 錯誤 $1(rc=$rc)" "$out"
}
e2 缺欄位 'delete b.scenes[1].lines' 'scenes\[1\].lines:必填'
e2 未知欄位 'b.scenes[1].card.foo=1' 'card.foo:不是可用欄位'
e2 圖不存在 'b.scenes[1].card.src="nope.png"' '找不到圖片 nope.png'
e2 at找不到 'b.scenes[2].card.at="沒有這個詞"' 'at「沒有這個詞」'
e2 同圖3次 'b.scenes[1].card.src="site.png";b.scenes[1].card.focus=[0,0,800,600];b.scenes[3].card={type:"image",src:"site.png",focus:[0,0,800,600]}' '同一個圖檔用在 3 個場景'
e2 星號不成對 'b.scenes[0].lines=["今天 *介紹 一個工具"]' '沒有成對'
e2 超過字數 'b.scenes[0].lines=["一二三四五六七八九十一二三四五六七八九十一"]' 'maxLineChars'
e2 姿勢 'b.scenes[0].mascot="dance"' '不是模板的姿勢'
e2 在asset-root外 'b.scenes[1].card.src="../sample.storyboard.json"' 'asset-root 外'
ln -sf /etc/hosts big/link.png; e2 symlink 'b.scenes[1].card.src="link.png"' 'asset-root 外' "$PWD/big"
e2 缺focus 'b.scenes[1].card={type:"image",src:"wide.png"}' 'focus 必填' "$PWD/big"
mkfix e-cnt.json 'b.scenes[0].lines.push("多一句")'
e="$(R e-cnt.json e/tts/tts.json e/w --deliver e/d --asset-root "$TPL/sample" 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q '重跑 tts.mjs' && ok "tts.json 句數和 storyboard 不符 → 結束碼 2" || bad "tts 句數" "$e"
e="$(R "$TPL/sample.storyboard.json" e/tts/tts.json e/w --asset-root "$TPL/sample" 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q -- '--deliver' && ok "沒給 --deliver → 結束碼 2" || bad "--deliver 必填" "$e"
[ ! -e e/w/silent.mp4 ] && ok "storyboard 錯誤時不產生任何輸出" || bad "錯誤時留下輸出"

# 7. 內容含 <script> / 外部 <img>:當純文字,不執行、不連線
mkfix inj.json 'b.scenes=b.scenes.slice(5,6);b.scenes[0].card.items=[{text:"<img src=//x.io/a.png>"},{text:"<script>x()</script>"}];b.scenes[0].headline=[["<b>粗</b>","<i>"]];b.scenes[0].lines=["<img src=//x.io/a>"]'
node "$KIT/tests/fake-tts.mjs" inj.json inj/tts >/dev/null
o="$(R inj.json inj/tts/tts.json inj/w --deliver inj/d --asset-root "$TPL/sample" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(jget "$(echo "$o" | tail -1)" blockedRequests)" = '[]' ] && grep -q '^<img src=//x.io/a>$' inj/d/subtitles.srt && ok "注入內容當純文字:沒有發出任何網路請求、字幕原樣保留" || bad "注入" "$o"

# 8. dry-run:印片長、rhythm、timing,不擷圖;節奏不合格時 rhythm.ok=false
o="$(R "$TPL/sample.storyboard.json" s1/tts/tts.json dr --dry-run --asset-root "$TPL/sample" 2>/dev/null)"; [ $? -eq 0 ] && [ ! -e dr ] && [ "$(jget "$o" rhythm.ok)" = true ] && [ -n "$(jget "$o" timing.changes)" ] && ok "--dry-run:印 duration / rhythm / timing,不寫檔" || bad "--dry-run" "$o"
mkfix rh.json 'b.scenes[2].card.at="1.2 萬"'
o="$(R rh.json s1/tts/tts.json dr --dry-run --asset-root "$TPL/sample" 2>&1)"; echo "$o" | grep -q '"ok":false' && echo "$o" | grep -q '間隔' && ok "rhythm:at 讓兩次畫面變化 < 2 秒 → ok:false 並在 stderr 說明" || bad "rhythm 判斷" "$o"

# 9. frame.mjs
mkdir -p job2/work/1
o="$(node "$S/frame.mjs" s1/out/final.mp4 5 job2/work/1/f.png)"; [ $? -eq 0 ] && [ "$(jget "$o" width)x$(jget "$o" height)" = 1080x1440 ] && ok "frame.mjs 擷一格到 <job>/work/<n>/" || bad "frame.mjs" "$o"
node "$S/frame.mjs" s1/out/final.mp4 5 elsewhere/f.png >/dev/null 2>&1; [ $? -eq 2 ] && ok "frame.mjs 輸出不在 <job>/work/<n>/ → 結束碼 2" || bad "frame.mjs 輸出限制"
node "$S/frame.mjs" s1/out/final.mp4 999 job2/work/1/g.png >/dev/null 2>&1; [ $? -eq 2 ] && ok "frame.mjs 秒數超過片長 → 結束碼 2" || bad "frame.mjs 秒數"

# 10. tts.mjs:假 ComfyUI(qwen3-tts-design 預設、--preset、不合格重生、--only)
PORT=$((20000 + RANDOM % 20000))
node "$GAK/tests/fake-comfy.mjs" "$PORT" "$T/req.log" > "$T/fake.out" 2>&1 & FPID=$!
for i in $(seq 1 50); do grep -q listening "$T/fake.out" 2>/dev/null && break; sleep 0.1; done
mkdir -p fh
cat > tts-sb.json <<'EOF'
{"scenes":[{"headline":[["測試",""]],"lines":["第一句 *旁白*",{"text":"第二句 SILENT","say":"第二句 SILENT 念法"},"第三句"]}]}
EOF
o="$(COMFYUI_URL="http://127.0.0.1:$PORT" HOME="$T/fh" GAK_CACHE_DIR="$T/fh/cache" node "$S/tts.mjs" tts-sb.json tq 2>tq.err)"; rc=$?
node -e '
const a=JSON.parse(process.argv[1]);const ok=a.length===3&&a[0].ok&&a[0].retries===0&&a[0].duration>0.5&&a[0].maxVolume>-30&&a[0].text==="第一句旁白"
 &&a[1].ok===false&&a[1].retries===2&&a[1].seed===7+202&&a[1].say==="第二句 SILENT 念法"&&a[2].ok&&a[0].voice==="design";process.exit(ok?0:1)' "$o" 2>/dev/null && [ $rc -eq 1 ] \
  && ok "tts.mjs(qwen3-tts-design):每句長度 / max_volume、無聲句換 seed 重生 2 次仍不合格 → ok:false、結束碼 1" || bad "tts.mjs qwen3" "rc=$rc $o $(tail -3 tq.err)"
grep -q '"design":' tq/raw/workflows/001-try0.json && grep -q 'qwen3-tts-design.json' tq/raw/workflows/001-try0.json && [ "$(ffprobe -v error -show_entries stream=sample_rate -of csv=p=0 tq/001.wav)" = 48000 ] && [ -f tq/tts-voice.json ] \
  && ok "tts.mjs:預設用聲音設計骨架、輸出 48 kHz WAV、記錄聲音參數 tts-voice.json" || bad "tts.mjs 輸出" "$(ls tq tq/raw/workflows)"
grep -q '念法' "$T/req.log" && ok "tts.mjs:念 say 欄位(念法改寫)而不是 text" || bad "tts.mjs say 欄位"
sed -i '' 's/SILENT/安靜/g' tts-sb.json
o="$(COMFYUI_URL="http://127.0.0.1:$PORT" HOME="$T/fh" GAK_CACHE_DIR="$T/fh/cache" node "$S/tts.mjs" tts-sb.json tq --only 2 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.length===3&&a.every(x=>x.ok)&&a[1].retries===0?0:1)' "$o" && ok "tts.mjs --only 2:只重生第 2 句,其他沿用" || bad "tts.mjs --only" "rc=$rc $o"
o="$(COMFYUI_URL="http://127.0.0.1:$PORT" HOME="$T/fh" GAK_CACHE_DIR="$T/fh/cache" node "$S/tts.mjs" tts-sb.json tp --preset Vivian --instruct 輕快 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && grep -q '"voice": "Vivian"' tp/raw/workflows/001-try0.json && grep -q 'Shared Runtime' tp/raw/workflows/001-try0.json && ok "tts.mjs --preset Vivian:走 CustomVoice 骨架(Shared Runtime)" || bad "tts.mjs --preset" "rc=$rc $o"
e="$(node "$S/tts.mjs" tts-sb.json tx --design x --preset Vivian 2>&1)"; [ $? -eq 2 ] && ok "tts.mjs:--design 與 --preset 同時給 → 結束碼 2" || bad "tts.mjs 參數衝突" "$e"
o="$(COMFYUI_URL="http://127.0.0.1:1" HOME="$T/fh" GAK_CACHE_DIR="$T/fh/c2" node "$S/tts.mjs" tts-sb.json tz 2>&1)"; [ $? -eq 5 ] && ok "tts.mjs:ComfyUI 連不上 → 結束碼 5" || bad "tts.mjs 連不上" "$o"
# 10b. 念法對照表:kit 的 pronunciation.json 自動套用(字幕不變)、--lexicon 專案覆蓋、--no-lexicon
cat > lex-sb.json <<'EOF2'
{"scenes":[{"headline":[["測試",""]],"lines":["例如 *一個網站*",{"text":"再一個網站","say":"再一個網站喔"}]}]}
EOF2
echo '{"words":{"網站":"往站"}}' > proj-lex.json
CF() { COMFYUI_URL="http://127.0.0.1:$PORT" HOME="$T/fh" GAK_CACHE_DIR="$T/fh/cache" node "$S/tts.mjs" "$@"; }
o="$(CF lex-sb.json tl 2>/dev/null)"; rc=$?
[ $rc -eq 0 ] && grep -q '網 站' tl/raw/workflows/001-try0.json && grep -q '網 站喔' tl/raw/workflows/002-try0.json \
  && node -e 'const a=JSON.parse(process.argv[1]);process.exit(a[0].text==="例如一個網站"&&a[0].spoken==="例如一個網 站"&&a[1].spoken==="再一個網 站喔"?0:1)' "$o" \
  && ok "tts.mjs:套用 kit pronunciation.json(網站 → 網 站,text 與 say 都套,字幕 text 不變,tts.json 記 spoken)" || bad "tts.mjs 念法對照表" "rc=$rc $o"
o="$(CF lex-sb.json tl2 --lexicon proj-lex.json 2>/dev/null)"; [ $? -eq 0 ] && grep -q '往站' tl2/raw/workflows/001-try0.json && ok "tts.mjs --lexicon:專案對照表覆蓋 kit 的同一個詞" || bad "tts.mjs --lexicon" "$o"
o="$(CF lex-sb.json tl3 --no-lexicon 2>/dev/null)"; [ $? -eq 0 ] && ! grep -q '網 站' tl3/raw/workflows/001-try0.json && grep -q '網站' tl3/raw/workflows/001-try0.json && ok "tts.mjs --no-lexicon:不套對照表" || bad "tts.mjs --no-lexicon" "$o"
echo '{"words":{"網站":""}}' > bad-lex.json
e="$(CF lex-sb.json tl4 --lexicon bad-lex.json 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q '網站' && ok "tts.mjs:對照表的值是空字串 → 結束碼 2 並指出詞" || bad "tts.mjs 壞對照表" "$e"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).words["網站"]==="網 站"||process.exit(1)' "$KIT/pronunciation.json" && ok "kit pronunciation.json 格式正確(含 2026-11-25 使用者回報的「網站」)" || bad "kit pronunciation.json"
kill "$FPID" 2>/dev/null; wait "$FPID" 2>/dev/null; FPID=""
if say -v '?' 2>/dev/null | grep -q '^Meijia '; then
  o="$(node "$S/tts.mjs" tts-sb.json ts --engine say 2>/dev/null)"; [ $? -eq 0 ] && node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.length===3&&a.every(x=>x.ok&&x.voice==="Meijia"&&x.duration>0.5)?0:1)' "$o" && ok "tts.mjs --engine say(Meijia)" || bad "tts.mjs say" "$o"
else skip "tts.mjs --engine say(沒有 Meijia 聲音)"; fi

# 10c. asr.mjs:比對邏輯(不需模型)+ 實際辨識(需 whisper-cli、模型、Meijia)
node --input-type=module -e '
import { asrDiff } from "'"$S"'/_lib.mjs";
const eq=(x,y)=>JSON.stringify(x)===JSON.stringify(y);
const c=[["選要重做什麼例如一個網站","選要重做什麼?例如一個獎斬。",[{expected:"網站",heard:"獎斬"}]],
 ["問它會傳什麼內建引擎","問他會傳什麼?內建引擎",[]],["開源工具叫Craft Anything","開源工具叫CraftAnything,",[]],
 ["純 Rust MIT或Apache雙授權","純REST MIT或APACH雙試拳",[{expected:"rust",heard:"rest"},{expected:"apache",heard:"apach"},{expected:"授權",heard:"試拳"}]],
 ["還能下載Ghidra反編譯","還能謝罪Gidre反編譯",[{expected:"下載",heard:"謝罪"},{expected:"ghidra",heard:"gidre"}]],["進階工作台","進階工作臺",[]]];
const bad=c.filter(([e,h,d])=>!eq(asrDiff(e,h).diffs,d));if(bad.length){console.log(JSON.stringify(bad.map(([e,h])=>asrDiff(e,h))));process.exit(1)}' \
  && ok "asrDiff:去標點、臺/台與它/他視為相同、英數字詞整個列出(Rust → rest)、網站 → 獎斬 被抓出" || bad "asrDiff"
mkdir -p ta && echo '[{"i":1,"text":"x","file":"001.wav","duration":1}]' > ta/tts.json
e="$(node "$S/asr.mjs" ta --model "$T/nope.bin" 2>&1)"; [ $? -eq 3 ] && ok "asr.mjs:缺模型檔或 whisper-cli → 結束碼 3" || bad "asr.mjs 缺模型" "$e"
WM="${SHORT_VIDEO_WHISPER_MODEL:-$HOME/.cache/whisper/ggml-large-v3-turbo.bin}"
if command -v whisper-cli >/dev/null 2>&1 && [ -s "$WM" ] && say -v '?' 2>/dev/null | grep -q '^Meijia '; then
  cat > asr-sb.json <<'EOF2'
{"scenes":[{"headline":[["測試",""]],"lines":["今天天氣很好",{"text":"這是一個網站","say":"這是一個獎斬"}]}]}
EOF2
  node "$S/tts.mjs" asr-sb.json tw --engine say --no-lexicon >/dev/null 2>&1
  o="$(node "$S/asr.mjs" tw 2>/dev/null)"; rc=$?
  [ $rc -eq 0 ] && [ -f tw/asr.json ] && node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.length===2&&a[0].diffs.length===0&&a[1].diffs.some(d=>d.expected.includes("網站"))?0:1)' "$o" \
    && ok "asr.mjs:念對的句子沒有出入;念成「獎斬」的句子列出「網站」(寫 asr.json)" || bad "asr.mjs 實際辨識" "rc=$rc $o"
  o="$(node "$S/asr.mjs" tw --only 2 2>/dev/null)"; [ $? -eq 0 ] && node -e 'process.exit(JSON.parse(process.argv[1]).length===2?0:1)' "$o" && ok "asr.mjs --only 2:只重測第 2 句,其他沿用" || bad "asr.mjs --only" "$o"
else skip "asr.mjs 實際辨識(缺 whisper-cli、模型 $WM 或 Meijia)"; fi

# 11. 60 秒片的渲染時間(印出,供估算)+ 成品驗證
mkfix long60.json 'const s=b.scenes.map(x=>JSON.parse(JSON.stringify(x)));b.scenes=[...s,...s.slice(1)]'
node "$KIT/tests/fake-tts.mjs" long60.json l60/tts --total 59.5 >/dev/null
t0=$(date +%s)
o="$(R long60.json l60/tts/tts.json l60/w --deliver l60/d --asset-root "$TPL/sample" 2>l60.err)"; rc=$?
secs=$(( $(date +%s) - t0 ))
if [ $rc -eq 0 ]; then
  node "$S/mix.mjs" l60/w/silent.mp4 l60/tts/tts.json l60/w/timing.json l60/d/final.mp4 >/dev/null 2>&1
  v="$(bash "$SVK/verify.sh" l60/d/final.mp4 l60/d/checks --size 1080x1440 --safe-json l60/w/safe.json --boxes l60/w/boxes.json --cover l60/d/cover.png --scenes l60/w/scenes.json)"
  [ $? -eq 0 ] && ok "60 秒片:片長 $(jget "$v" duration) 秒、$(jget "$o" frames) 格,渲染 ${secs} 秒(擷圖 + 編碼 $(jget "$o" renderSeconds) 秒),verify 通過" || bad "60 秒片 verify" "$v"
else bad "60 秒片渲染" "$o $(tail -3 l60.err)"; fi
echo "RENDER_60S_SECONDS=$secs"

# 12. Chrome 不殘留
sleep 1
left="$(find "$SHORT_VIDEO_KIT_TMP" -maxdepth 1 -name 'chrome-*' | wc -l | tr -d ' ')"
procs="$(pgrep -f -- "--user-data-dir=.*/$(basename "$SHORT_VIDEO_KIT_TMP")/chrome-" | wc -l | tr -d ' ')"
[ "$left" = 0 ] && [ "$procs" = 0 ] && ok "跑完沒有殘留 Chrome 設定檔與程序" || bad "Chrome 殘留" "dirs=$left procs=$procs"
[ -z "$(ls -A "$TPL/preview" 2>/dev/null | grep -v -E '^(contact|scene-[0-9]+)\.png$')" ] && ok "測試沒有寫進 kit 的 preview/" || bad "kit preview 被寫入" "$(ls -A "$TPL/preview")"

echo "結果:$PASS 通過,$FAIL 失敗,$SKIP 略過"
[ $FAIL -eq 0 ] || exit 1
[ $SKIP -eq 0 ] || exit 3
