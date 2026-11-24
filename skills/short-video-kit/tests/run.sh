#!/bin/bash
# short-video-kit 自我測試。用法:bash tests/run.sh
# 缺 ffmpeg / Chrome 時印 SKIP 並以結束碼 3 結束(SKIP 不算通過)。
# transcribe.sh 只在有 whisper-cli 與模型檔時測,否則該項 SKIP。結束時刪除所有暫存檔。
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/scripts"
WDK="$(cd "$KIT/../web-dev-kit/scripts" 2>/dev/null && pwd || true)"
export SHORT_VIDEO_KIT_TMP="$(mktemp -d "${TMPDIR:-/tmp}/svk-test-kit.XXXXXX")"
T="$(mktemp -d "${TMPDIR:-/tmp}/svk-test.XXXXXX")"
cleanup() {
  [ -n "$WDK" ] && bash "$WDK/stop.sh" svk-selftest >/dev/null 2>&1
  rm -rf "${WEB_DEV_KIT_TMP:-${TMPDIR:-/tmp}/web-dev-kit}/svk-selftest"
  rm -rf "$T" "$SHORT_VIDEO_KIT_TMP"
}
trap cleanup EXIT

PASS=0; FAIL=0; SKIP=0
ok() { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad() { echo "FAIL  $1"; [ -n "${2:-}" ] && echo "      $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
jget() { node -e 'const j=JSON.parse(process.argv[1]);const v=process.argv[2].split(".").reduce((o,k)=>o?.[k],j);console.log(typeof v==="object"?JSON.stringify(v):v)' "$1" "$2"; }

if ! command -v ffmpeg >/dev/null 2>&1 || [ ! -x "${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}" ]; then
  echo "SKIP  全部:缺 ffmpeg 或 Google Chrome(SKIP 不算通過)"; exit 3
fi
cd "$T"

# --- 測試素材 -------------------------------------------------------------
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=1920x1080:r=30:d=10 \
  -f lavfi -i "aevalsrc='if(between(t,3,5),0,0.3*sin(2*PI*440*t))':s=48000:d=10" \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest land.mp4
ffmpeg -hide_banner -loglevel error -y -display_rotation 90 -i land.mp4 -c copy rot.mp4
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=1280x720:r=25:d=3 -c:v libx264 -an bad.mp4
# 桌面 App 錄影的比例(2026-11-18 craft-anything 第二版的素材 1000×1400)
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=1000x1400:r=30:d=4 -c:v libx264 -pix_fmt yuv420p -an app.mp4

# 1. check.sh
out="$(bash "$S/check.sh")"; [ $? -eq 0 ] && echo "$out" | grep -q all-ok && ok "check.sh 基本工具齊全" || bad "check.sh" "$out"

# 2. probe.sh(橫式、旋轉)
p="$(bash "$S/probe.sh" land.mp4)"
[ "$(jget "$p" width)x$(jget "$p" height)" = "1920x1080" ] && [ "$(jget "$p" hasAudio)" = true ] && ok "probe.sh 橫式" || bad "probe.sh 橫式" "$p"
p="$(bash "$S/probe.sh" rot.mp4)"
[ "$(jget "$p" width)x$(jget "$p" height)" = "1080x1920" ] && [ "$(jget "$p" rotation)" = 90 ] && ok "probe.sh 套用旋轉" || bad "probe.sh 旋轉" "$p"

# 3. silence.sh
sil="$(bash "$S/silence.sh" land.mp4)"
node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.length===1&&Math.abs(a[0].start-3)<0.1&&Math.abs(a[0].end-5)<0.1?0:1)' "$sil" \
  && ok "silence.sh 找到 3–5 秒停頓" || bad "silence.sh" "$sil"
bash "$S/silence.sh" bad.mp4 >/dev/null 2>&1; [ $? -eq 3 ] && ok "silence.sh 沒有音軌 → 結束碼 3" || bad "silence.sh 沒有音軌"

# 4. tts.sh
printf '第一句旁白。\n\n第二句旁白比較長一點。\n' > s.txt
tts="$(bash "$S/tts.sh" s.txt tts 2>/dev/null)"
node -e 'const a=JSON.parse(process.argv[1]);process.exit(a.length===2&&a.every(x=>x.duration>0.5)?0:1)' "$tts" \
  && ok "tts.sh 兩句(略過空行)、各有長度" || bad "tts.sh" "$tts"

# 5. render.mjs:卡片、注入內容、安全區、縮字、路徑限制
mkdir -p assets; ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=800x500 -frames:v 1 assets/shot.png
cat > cards.json <<'EOF'
{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#ff8800","muted":"#a0a0a0"},"cards":[
 {"type":"title","file":"t.png","title":"測試標題","subtitle":"副標"},
 {"type":"point","file":"p.png","number":"1","title":"注入測試","body":"<script>fetch('https://example.com/x')</script><img src=\"https://example.com/x.png\">","image":"shot.png"},
 {"type":"code","file":"c.png","path":"a.js","code":"const a = 1;\n// x"},
 {"type":"subtitle","file":"s1.png","text":"短字幕"},
 {"type":"subtitle","file":"s2.png","text":"這一句字幕稍微長一點需要縮小字級才放得下兩行喔對吧"}
]}
EOF
r="$(node "$S/render.mjs" cards.json r --asset-root assets)"; rc=$?
[ $rc -eq 0 ] && [ -f r/t.png ] && [ -f r/p.png ] && [ -f r/c.png ] && ok "render.mjs 產生卡片" || bad "render.mjs 產生卡片" "$r"
[ "$(jget "$r" blockedRequests)" = "[]" ] && ok "render.mjs 注入內容當純文字(沒有發出任何請求)" || bad "render.mjs 注入" "$r"
dim="$(ffprobe -v error -show_entries stream=width,height -of csv=s=x:p=0 r/p.png)"; [ "$dim" = 1080x1920 ] && ok "render.mjs 1080×1920" || bad "render.mjs 尺寸" "$dim"
b="$(cat r/boxes.json 2>/dev/null)"
node -e 'const b=JSON.parse(process.argv[1]);const s=b.find(x=>x.file==="s2.png");process.exit(b.length===2&&s&&s.fontSize<64&&s.lines<=2&&b.every(x=>x.x>=60&&x.x+x.w<=930&&x.y>=1300&&x.y+x.h<=1620)?0:1)' "$b" \
  && ok "render.mjs 字幕縮字、在安全區內" || bad "render.mjs 縮字" "$b"
echo '{"cards":[{"type":"subtitle","text":"這是一句非常非常長的字幕這是一句非常非常長的字幕這是一句非常非常長的字幕這是一句非常非常長的字幕這是一句非常非常長的字幕"}]}' > long.json
node "$S/render.mjs" long.json r2 >/dev/null 2>&1; [ $? -eq 4 ] && ok "render.mjs 字幕放不下 → 結束碼 4" || bad "render.mjs 放不下"
echo '{"cards":[{"type":"cover","file":"ic.png","image":"shot.png","title":"■■■"}]}' > ic.json
node "$S/render.mjs" ic.json r6 --asset-root assets >/dev/null 2>&1 && [ "$(ffmpeg -hide_banner -loglevel error -i r6/ic.png -vf 'crop=1:1:110:320,format=rgb24' -f rawvideo - | od -An -tu1 | awk 'NF{print ($1>200&&$2>200&&$3>200)?"white":"dark"}')" = white ] && ok "render.mjs 有圖封面不需要 theme、標題白字" || bad "render.mjs 有圖封面白字"
echo '[{"type":"title","title":"x"}]' > arr.json
e="$(node "$S/render.mjs" arr.json r6 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q '物件格式' && ok "render.mjs 陣列格式 + 需要 theme → 結束碼 2 並提示物件格式" || bad "render.mjs 陣列格式" "$e"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#ff8800","muted":"#a0a0a0"},"cards":[{"type":"point","title":"x","image":"../cards.json"}]}' > esc.json
node "$S/render.mjs" esc.json r3 --asset-root assets >/dev/null 2>&1; [ $? -eq 1 ] && ok "render.mjs 擋 asset-root 外的圖" || bad "render.mjs asset-root 外"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#ff8800","muted":"#a0a0a0"},"cards":[{"type":"point","title":"x","image":"https://example.com/a.png"}]}' > ext.json
node "$S/render.mjs" ext.json r3 --asset-root assets >/dev/null 2>&1; [ $? -eq 1 ] && ok "render.mjs 擋遠端圖片網址" || bad "render.mjs 遠端圖片"
ln -s /etc/hosts assets/link.png
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#ff8800","muted":"#a0a0a0"},"cards":[{"type":"point","title":"x","image":"link.png"}]}' > lnk.json
node "$S/render.mjs" lnk.json r3 --asset-root assets >/dev/null 2>&1; [ $? -eq 1 ] && ok "render.mjs 擋指到外面的 symlink" || bad "render.mjs symlink"

echo '{"cards":[{"type":"title","file":"x.png","title":"沒有配色"}]}' > nothm.json
e="$(node "$S/render.mjs" nothm.json r5 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'theme 缺' && ok "render.mjs 沒有 theme → 結束碼 2(沒有預設配色)" || bad "render.mjs 沒有 theme 沒被擋" "$e"
echo '{"theme":{"bg":"#888888","bg2":"#888888","fg":"#777777","accent":"#ff8800","muted":"#a0a0a0"},"cards":[{"type":"title","file":"x.png","title":"低對比"}]}' > lowc.json
e="$(node "$S/render.mjs" lowc.json r5 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q '對比' && ok "render.mjs fg 對比不足 → 結束碼 2" || bad "render.mjs 低對比沒被擋" "$e"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#ff8800","muted":"#3a4a5a"},"cards":[{"type":"title","file":"x.png","title":"副標太暗","subtitle":"看不清楚"}]}' > lowm.json
e="$(node "$S/render.mjs" lowm.json r5 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'theme.muted 對 bg~bg2' && ok "render.mjs 副標 muted 對比不足 → 結束碼 2" || bad "render.mjs muted 低對比沒被擋" "$e"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#304860","muted":"#3a4a5a"},"cards":[{"type":"title","file":"x.png","title":"沒有副標與 tag"}]}' > nomuted.json
o="$(node "$S/render.mjs" nomuted.json r5 2>&1)"; [ $? -eq 0 ] && ! echo "$o" | grep -q 'muted/' && ok "render.mjs 沒畫出來的顏色不檢查(沒有副標就不查 muted)" || bad "render.mjs 檢查了沒畫出來的顏色" "$o"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#304860","muted":"#a0a0a0"},"cards":[{"type":"point","file":"x.png","number":"1","title":"徽章看不到"}]}' > lowa.json
e="$(node "$S/render.mjs" lowa.json r5 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'theme.bg 對 accent' && ok "render.mjs accent 與 bg 對比不足(徽章 / tag)→ 結束碼 2" || bad "render.mjs accent 低對比沒被擋" "$e"
echo '{"theme":{"bg":"#ee0000","bg2":"#00aa00","fg":"#000000","accent":"#ffffff","muted":"#000000"},"cards":[{"type":"title","file":"x.png","title":"漸層中段"}]}' > midgrad.json
e="$(node "$S/render.mjs" midgrad.json r5 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'bg~bg2' && ok "render.mjs 漸層兩端夠、中段不夠 → 結束碼 2" || bad "render.mjs 漸層中段沒被擋" "$e"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#203040","muted":"#a0a0a0"},"cards":[{"type":"point","file":"x.png","title":"徽章 0","number":0}]}' > num0.json
e="$(node "$S/render.mjs" num0.json r5 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'theme.bg 對 accent' && ok "render.mjs number 為 0 也檢查徽章對比" || bad "render.mjs number 0 漏檢" "$e"
echo '{"theme":{"bg":"#101010","bg2":"#101010","fg":"#181818","accent":"#ffcc00","muted":"#181818"},"cards":[{"type":"headline","file":"h.png","text":"只有標題"}]}' > hlonly.json
o="$(node "$S/render.mjs" hlonly.json r5 2>&1)"; [ $? -eq 0 ] && echo "$o" | grep -q '"bg/accent"' && ! echo "$o" | grep -q '"fg/' && ok "render.mjs 只有 headline 時只檢查 bg/accent,輸出 contrast" || bad "render.mjs headline 對比檢查" "$o"
echo '{"cards":[{"type":"subtitle","file":"s.png","text":"只有字幕"}]}' > subonly.json
node "$S/render.mjs" subonly.json r5 >/dev/null 2>&1 && ok "render.mjs 只有字幕卡時不需要 theme" || bad "render.mjs 字幕卡不該要求 theme"
echo '{"theme":{"bg":"#000","extra":1},"cards":[{"type":"subtitle","file":"s.png","text":"舊格式 theme"}]}' > oldthm.json
node "$S/render.mjs" oldthm.json r5 >/dev/null 2>&1 && ok "render.mjs 只有字幕卡時忽略 theme 格式(舊 timeline 相容)" || bad "render.mjs 字幕卡不該檢查 theme 格式"
echo '{"theme":{"bg":"#203040","bg2":"#304050","fg":"#ffffff","accent":"#ff8800","muted":"#a0a0a0"},"cards":[{"type":"cover","file":"cv.png","tag":"repo","title":"漸層封面"}]}' > cv.json
node "$S/render.mjs" cv.json r4 >/dev/null 2>&1 && [ "$(ffprobe -v error -show_entries stream=width,height -of csv=s=x:p=0 r4/cv.png)" = 1080x1920 ] && ok "render.mjs 沒有圖片的漸層封面" || bad "render.mjs 漸層封面"

# 6. record-web.mjs
if [ -n "$WDK" ]; then
  mkdir -p site
  cat > site/index.html <<'EOF'
<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<link rel="stylesheet" href="https://fonts.googleapis.com/css?family=Roboto"></head>
<body style="margin:0;font-family:sans-serif"><h1 style="background:#38bdf8;margin:0;padding:20px">Demo</h1>
<input id="q"><button id="b" onclick="document.body.insertAdjacentHTML('beforeend','<p>'+q.value+'</p>')">新增</button>
<div style="height:2000px;background:linear-gradient(#fff,#f0a)"></div></body></html>
EOF
  echo '[{"do":"goto","url":"/"},{"do":"type","selector":"#q","text":"牛奶"},{"do":"click","selector":"#b"},{"do":"scroll","y":800,"ms":800}]' > act.json
  sv="$(bash "$WDK/serve.sh" svk-selftest site 8790 -- python3 -m http.server {port} --bind 127.0.0.1 2>&1)"
  url="$(echo "$sv" | sed -n 's/.*url=\([^ ]*\).*/\1/p')"
  rec="$(node "$S/record-web.mjs" "$url" act.json rec.mp4)"; rc=$?
  bash "$WDK/stop.sh" svk-selftest >/dev/null
  p="$(bash "$S/probe.sh" rec.mp4 2>/dev/null || echo '{}')"
  [ $rc -eq 0 ] && [ "$(jget "$p" width)x$(jget "$p" height)" = 1080x1920 ] && [ "$(jget "$p" fps)" = 30 ] && ok "record-web.mjs 1080×1920 30fps" || bad "record-web.mjs" "$rec $p"
  node -e 'const r=JSON.parse(process.argv[1]);const m=r.marks;process.exit(m.length===3&&m.every((x,i)=>i===0||x.t>m[i-1].t)&&m[2].t<r.duration?0:1)' "$rec" && ok "record-web.mjs marks 依序遞增" || bad "record-web.mjs marks" "$rec"
  echo "$rec" | grep -q 'fonts.googleapis.com' && ok "record-web.mjs 擋外部請求並回報" || bad "record-web.mjs 外部請求" "$rec"
  node "$S/record-web.mjs" https://example.com act.json x.mp4 >/dev/null 2>&1; [ $? -eq 2 ] && ok "record-web.mjs 拒絕非本機網址" || bad "record-web.mjs 非本機"
else skip "record-web.mjs(找不到 web-dev-kit)"; fi

# 7. compose.mjs 旁白模式 + verify.sh
mkdir -p job/1 job/work/1
cp tts/*.m4a job/work/1/ 2>/dev/null
node -e '
const fs=require("fs");const n=JSON.parse(process.argv[1]).map((x,i)=>({...x,file:"../work/1/"+require("path").basename(x.file)}));
fs.writeFileSync("job/1/timeline.json",JSON.stringify({mode:"narration",work:"../work/1",narration:n,theme:{bg:"#203040"},
 scenes:[{image:"../../r/t.png",sentences:[0]},{video:"../../land.mp4",in:1,sentences:[1]}],music:{path:"../../land.mp4",volume:0.2}}))' "$tts"
c="$(node "$S/compose.mjs" job/1/timeline.json)"; rc=$?
[ $rc -eq 0 ] && [ -f job/1/final.mp4 ] && [ -f job/work/1/first-frame.png ] && ok "compose.mjs 旁白模式" || bad "compose.mjs 旁白" "$c"
node -e '
const fs=require("fs");const tts=JSON.parse(process.argv[1]);
const srt=fs.readFileSync("job/1/subtitles.srt","utf8").trim().split(/\n\n/).map(b=>{const l=b.split("\n");const [a,z]=l[1].split(" --> ").map(t=>{const [h,m,s]=t.replace(",",".").split(":");return h*3600+m*60+Number(s)});return {a,z,text:l[2]}});
let t=0.3,ok=srt.length===tts.length;
tts.forEach((x,i)=>{const s=i===0?0.3:t+0.25,e=s+x.duration;if(Math.abs(srt[i].a-s)>0.05||Math.abs(srt[i].z-e)>0.05||srt[i].text!==x.text)ok=false;t=e});
process.exit(ok?0:1)' "$tts" && ok "SRT 時間 = tts 長度公式(0.3 起、間隔 0.25)" || bad "SRT 公式" "$(cat job/1/subtitles.srt)"
echo '{"cards":[{"type":"cover","file":"cover.png","image":"first-frame.png","title":"封面"}]}' > job/work/1/c.json
node "$S/render.mjs" job/work/1/c.json job/1 --asset-root job/work/1 >/dev/null
v="$(bash "$S/verify.sh" job/1/final.mp4 job/1/checks --boxes job/work/1/subtitles/boxes.json --cover job/1/cover.png --scenes job/work/1/scenes.json)"; rc=$?
[ $rc -eq 0 ] && [ "$(ls job/1/checks | wc -l | tr -d ' ')" = 9 ] && [ "$(jget "$v" sceneChecks | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).length)')" = 4 ] \
  && ok "verify.sh 旁白成品通過、5 張 + 每個鏡頭中點與結尾各 1 張" || bad "verify.sh 旁白成品" "$v"
bash "$S/verify.sh" job/1/final.mp4 chk3 --boxes job/work/1/subtitles/boxes.json --cover job/1/cover.png >/dev/null 2>&1; [ $? -ne 0 ] && ok "verify.sh 沒給 --scenes → 失敗" || bad "verify.sh 缺 --scenes"
echo '[{"start":0,"end":1}]' > short-scenes.json
v="$(bash "$S/verify.sh" job/1/final.mp4 chk4 --boxes job/work/1/subtitles/boxes.json --cover job/1/cover.png --scenes short-scenes.json)"; rc=$?
[ $rc -eq 1 ] && echo "$v" | grep -q '鏡頭表 gap' && ok "verify.sh 鏡頭表沒涵蓋整支 → 失敗" || bad "verify.sh 鏡頭表不符" "$v"
[ "$(jget "$c" scenes.1.layout)" = top ] && [ "$(jget "$c" scenes.1.uiBottom)" -le 1280 ] && ok "橫式錄影鏡頭置頂、下緣 ≤ 1280(不被 fit 裁切)" || bad "橫式鏡頭置頂" "$c"

# 7a. verify.sh --size / --safe-json(motion-video-kit 用;依 boxes 的 kind 比對,沒有 kind 當 subtitle)
v="$(bash "$S/verify.sh" job/1/final.mp4 chk5 --boxes job/work/1/subtitles/boxes.json --cover job/1/cover.png --scenes job/work/1/scenes.json --size 1080x1440)"; rc=$?
[ $rc -eq 1 ] && echo "$v" | grep -q '應為 1080x1440' && ok "verify.sh --size 1080x1440 對 1080×1920 成品 → 失敗(影片與封面都比)" || bad "verify.sh --size" "$v"
echo '{"subtitle":[60,1300,930,1620],"headline":[0,0,1080,400]}' > safe.json
v="$(bash "$S/verify.sh" job/1/final.mp4 chk6 --boxes job/work/1/subtitles/boxes.json --cover job/1/cover.png --scenes job/work/1/scenes.json --safe-json safe.json)"; rc=$?
[ $rc -eq 0 ] && ok "verify.sh --safe-json:沒有 kind 的框當 subtitle 比對" || bad "verify.sh --safe-json 無 kind" "$v"
echo '[{"file":"h1","kind":"headline","x":40,"y":100,"w":700,"h":250},{"file":"s1","kind":"subtitle","x":100,"y":1350,"w":500,"h":80}]' > kb.json
v="$(bash "$S/verify.sh" job/1/final.mp4 chk7 --boxes kb.json --cover job/1/cover.png --scenes job/work/1/scenes.json --safe-json safe.json)"; rc=$?
[ $rc -eq 0 ] && ok "verify.sh --safe-json:headline 框用 headline 矩形" || bad "verify.sh kind headline" "$v"
echo '[{"file":"h1","kind":"headline","x":40,"y":300,"w":700,"h":250}]' > kb2.json
v="$(bash "$S/verify.sh" job/1/final.mp4 chk8 --boxes kb2.json --cover job/1/cover.png --scenes job/work/1/scenes.json --safe-json safe.json)"; rc=$?
[ $rc -eq 1 ] && echo "$v" | grep -q 'h1(headline)' && ok "verify.sh --safe-json:headline 框超出 → 失敗並指出" || bad "verify.sh headline 越界" "$v"
e="$(bash "$S/verify.sh" job/1/final.mp4 chk9 --boxes kb.json --cover job/1/cover.png --scenes job/work/1/scenes.json --size 1080 2>&1)"; [ $? -eq 2 ] && ok "verify.sh --size 格式錯 → 結束碼 2" || bad "verify.sh --size 格式" "$e"
out="$(bash "$S/check.sh" --no-say)"; [ $? -eq 0 ] && echo "$out" | grep -q 'skip    say' && ok "check.sh --no-say 不檢查 say" || bad "check.sh --no-say" "$out"

# 7b. 置頂鏡頭:第二版的設定(1000×1400 錄影、整支 fit crop、沒有 region)要被擋;設 region 後 UI 在字幕區上方
node -e '
const fs=require("fs");const n=JSON.parse(process.argv[1]).map((x,i)=>({...x,file:"../work/1/"+require("path").basename(x.file)}));
const mk=(sc,extra={})=>JSON.stringify({mode:"narration",work:"../work/1",narration:n,fit:"crop",theme:{bg:"#203040"},...extra,scenes:sc});
fs.writeFileSync("job/1/v2.json",mk([{video:"../../app.mp4",sentences:[0]},{video:"../../app.mp4",in:1,sentences:[1]}]));
fs.writeFileSync("job/1/v3.json",mk([{video:"../../app.mp4",region:[250,40,745,830],sentences:[0]},{video:"../../app.mp4",in:1,region:[335,40,665,700],sentences:[1]}],{out:"v3",theme:{bg:"#203040"}}));
fs.writeFileSync("job/1/v3-nothm.json",mk([{video:"../../app.mp4",region:[250,40,745,830],sentences:[0,1]}],{out:"v3n",theme:undefined}));
fs.writeFileSync("job/1/bad-region.json",mk([{video:"../../app.mp4",region:[500,0,600,700],sentences:[0,1]}]));' "$tts"
e="$(node "$S/compose.mjs" job/1/v2.json --dry-run 2>&1)"; [ $? -eq 6 ] && echo "$e" | grep -q 'region' && ok "第二版設定(高錄影、沒有 region)→ 結束碼 6,提示設 region" || bad "第二版設定沒被擋" "$e"
node "$S/compose.mjs" job/1/bad-region.json --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "region 超出來源 → 結束碼 2" || bad "region 超出來源"
e="$(node "$S/compose.mjs" job/1/v3-nothm.json --dry-run 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'theme.bg' && ok "置頂鏡頭沒有 theme.bg → 結束碼 2(沒有預設底色)" || bad "置頂沒有 theme.bg 沒被擋" "$e"
c3="$(node "$S/compose.mjs" job/1/v3.json)"; rc=$?
px() { ffmpeg -hide_banner -loglevel error -i "$1" -vf "crop=1:1:$2:$3,format=rgb24" -f rawvideo - | od -An -tu1 | tr -s ' ' | sed 's/^ //'; }
[ $rc -eq 0 ] && [ "$(jget "$c3" scenes.0.uiBottom)" -le 1280 ] && [ "$(jget "$c3" scenes.1.uiBottom)" -le 1280 ] && node -e 'const p=process.argv[1].trim().split(" ").map(Number);process.exit([32,48,64].every((v,i)=>Math.abs(p[i]-v)<=4)?0:1)' "$(px job/work/1/first-frame.png 540 1500)" \
  && ok "設 region 後置頂:UI 下緣 ≤ 1280、字幕區是 theme.bg" || bad "置頂鏡頭" "$c3 px=$(px job/work/1/first-frame.png 540 1500)"

# 7c. AI 素材:frames.sh 組影格、圖片 fill / motion、影片鏡頭 fit 覆寫與 hold、sfx
mkdir -p ai
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=704x1280:r=24:d=2 -start_number 1 ai/clip-%d.png
f="$(bash "$S/frames.sh" ai clip ai/clip.mp4 --frames 48)"; rc=$?
[ $rc -eq 0 ] && [ "$(jget "$f" frames)" = 48 ] && [ "$(jget "$f" width)x$(jget "$f" height)" = 704x1280 ] && [ "$(bash "$S/probe.sh" ai/clip.mp4 | node -e 'console.log(JSON.parse(require("fs").readFileSync(0,"utf8")).fps)')" = 24 ] \
  && ok "frames.sh 48 格 → 24 fps MP4" || bad "frames.sh" "$f"
mkdir -p ai2 && cp ai/clip-1.png ai/clip-2.png ai/clip-4.png ai2/
e="$(bash "$S/frames.sh" ai2 clip x.mp4 --frames 4 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'clip-3.png' && ok "frames.sh 缺第 3 格 → 結束碼 2 並指出缺哪格" || bad "frames.sh 缺號沒被擋" "$e"
mkdir -p ai3 && cp ai/clip-1.png ai3/clip-1-1.png && cp ai/clip-2.png ai3/clip-1-2.png && cp ai/clip-1.png ai3/clip-1-r2-1.png && cp ai/clip-2.png ai3/clip-1-r2-2.png
f3="$(bash "$S/frames.sh" ai3 clip-1 ai3/a.mp4 --frames 2 2>&1)" && [ "$(jget "$f3" frames)" = 2 ] && ok "frames.sh 不把重出的 <名稱>-r2-*.png 算進來" || bad "frames.sh 重出影格混入" "$f3"
mkdir -p ai4 && for i in 1 2 3 4 5; do cp ai/clip-$i.png ai4/c-$i.png; done
e="$(bash "$S/frames.sh" ai4 c x.mp4 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q -- '缺 --frames' && ok "frames.sh 沒給 --frames → 結束碼 2(必填)" || bad "frames.sh --frames 必填" "$e"
f4="$(bash "$S/frames.sh" ai4 c ai4/a.mp4 --frames 3 2>&1)"
[ "$(jget "$f4" frames)" = 3 ] && ok "frames.sh --frames 3:同名重跑留下的 4、5 格被忽略" || bad "frames.sh --frames" "$f4"
e2="$(bash "$S/frames.sh" ai4 c x.mp4 --frames 6 2>&1)"; [ $? -eq 2 ] && echo "$e2" | grep -q '少於 --frames' && ok "frames.sh --frames 多於現有格數 → 結束碼 2" || bad "frames.sh --frames 6" "$e2"
ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc2=s=928x1664 -frames:v 1 ai/img-1.png
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "sine=f=880:d=0.4" -ar 48000 ai/sfx-1.wav
node -e '
const fs=require("fs");const n=JSON.parse(process.argv[1]).map((x,i)=>({...x,file:"../work/1/"+require("path").basename(x.file)}));
const mk=(sc,extra={})=>JSON.stringify({mode:"narration",work:"../work/ai",out:"ai",narration:n,...extra,scenes:sc});
fs.writeFileSync("job/1/ai.json",mk([{image:"../../ai/img-1.png",motion:"in",sfx:{path:"../../ai/sfx-1.wav",volume:0.8},sentences:[0]},{video:"../../ai/clip.mp4",fit:"crop",sentences:[1]}]));
fs.writeFileSync("job/1/ai-badm.json",mk([{image:"../../ai/img-1.png",motion:"zoom",sentences:[0,1]}]));
fs.writeFileSync("job/1/ai-vmotion.json",mk([{video:"../../ai/clip.mp4",motion:"in",sentences:[0,1]}]));
fs.writeFileSync("job/1/ai-ifit.json",mk([{image:"../../ai/img-1.png",fit:"crop",sentences:[0,1]}]));
fs.writeFileSync("job/1/ai-sfxs.json",mk([{image:"../../ai/img-1.png",fill:true,sfx:{path:"../../ai/sfx-1.wav",volume:""},sentences:[0,1]}]));
fs.writeFileSync("job/1/ai-sfx0.json",mk([{image:"../../ai/img-1.png",fill:true,sfx:{path:"../../ai/sfx-1.wav",volume:0},sentences:[0,1]}]));
fs.writeFileSync("job/1/ai-fill.json",mk([{image:"../../ai/img-1.png",fill:true,sentences:[0,1]}],{out:"aif",work:"../work/aif"}));' "$tts"
node "$S/compose.mjs" job/1/ai-badm.json --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "compose.mjs motion 不合法 → 結束碼 2" || bad "compose.mjs motion 不合法沒被擋"
node "$S/compose.mjs" job/1/ai-vmotion.json --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "compose.mjs 影片鏡頭帶 motion → 結束碼 2" || bad "影片鏡頭 motion 沒被擋"
node "$S/compose.mjs" job/1/ai-ifit.json --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "compose.mjs 圖片鏡頭帶 fit → 結束碼 2" || bad "圖片鏡頭 fit 沒被擋"
node "$S/compose.mjs" job/1/ai-sfxs.json --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "compose.mjs sfx volume 空字串 → 結束碼 2(不當成靜音)" || bad "sfx volume 空字串沒被擋"
o0="$(node "$S/compose.mjs" job/1/ai-sfx0.json --dry-run 2>&1)" && ! echo "$o0" | grep -q '"sfx"' && ok "compose.mjs sfx volume 0 → 接受、不混音" || bad "sfx volume 0" "$o0"
mkdir -p 'p%d' && cp ai/clip-1.png ai/clip-2.png 'p%d/' && { bash "$S/frames.sh" 'p%d' clip x.mp4 --frames 2 >/dev/null 2>&1; [ $? -eq 2 ]; } && ok "frames.sh 目錄含 % → 結束碼 2" || bad "frames.sh % 目錄沒被擋"
ca="$(node "$S/compose.mjs" job/1/ai.json)"; rc=$?
node -e '
const c=JSON.parse(process.argv[1]);const s=c.scenes;
const want=Math.max(0,(s[1].end-s[1].start)-2);
process.exit(s[0].motion==="in"&&s[1].layout==="crop"&&Math.abs(s[1].hold-want)<0.05&&c.sfx?.length===1&&c.sfx[0].at===0?0:1)' "$ca" 2>/dev/null \
  && ok "compose.mjs motion / 鏡頭 fit / hold / sfx 摘要正確" || bad "compose.mjs AI 鏡頭摘要" "$ca"
# motion:第 0 格與鏡頭結尾畫面不同(有在推近);fill:左上角不是黑邊
ffmpeg -hide_banner -loglevel error -y -ss "$(jget "$ca" scenes.0.end | node -e 'console.log(Math.max(0,Number(require("fs").readFileSync(0,"utf8"))-0.1))')" -i job/1/ai/final.mp4 -frames:v 1 ai/end0.png
ffmpeg -hide_banner -loglevel error -y -i job/1/ai/final.mp4 -frames:v 1 ai/start0.png
[ $rc -eq 0 ] && [ "$(px ai/start0.png 200 200)" != "$(px ai/end0.png 200 200)" ] && ok "motion in:鏡頭開頭與結尾畫面不同" || bad "motion 沒有動" "$(px ai/start0.png 200 200) / $(px ai/end0.png 200 200)"
cf="$(node "$S/compose.mjs" job/1/ai-fill.json)" && node -e 'const p=process.argv[1].trim().split(" ").map(Number);process.exit(p.some(v=>v>30)?0:1)' "$(px job/work/aif/first-frame.png 4 4)" \
  && ok "fill:等比蓋滿,左上角不是黑邊" || bad "fill" "$cf px=$(px job/work/aif/first-frame.png 4 4)"
vol() { ffmpeg -hide_banner -nostats -i "$1" -ss "$2" -t "$3" -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p'; }
node -e 'process.exit(Number(process.argv[1])>-30?0:1)' -- "$(vol job/1/ai/final.mp4 0 0.3)" && ok "sfx 在鏡頭開始(旁白前 0.3 秒有聲音)" || bad "sfx 沒混進去" "$(vol job/1/ai/final.mp4 0 0.3)"

# 7d. Chrome 設定檔不殘留:正常結束與被 SIGTERM 中止都要刪掉 chrome-* 並殺掉 Chrome(子程序會寫回 Reporting and NEL-journal)
# $TMPDIR 結尾有 / 時路徑會有 //,Chrome 參數用的是正規化後的路徑:用資料夾名稱比對
chromes() { pgrep -f -- "--user-data-dir=.*/$(basename "$SHORT_VIDEO_KIT_TMP")/chrome-" | wc -l | tr -d ' '; }
left() { find "$SHORT_VIDEO_KIT_TMP" -maxdepth 1 -name 'chrome-*' | wc -l | tr -d ' '; }
sleep 1
[ "$(left)" = 0 ] && [ "$(chromes)" = 0 ] && ok "前面各項跑完後沒有殘留 chrome-* 設定檔與 Chrome 程序" || bad "Chrome 殘留" "dirs=$(left) procs=$(chromes) $(find "$SHORT_VIDEO_KIT_TMP" | head -5 | tr '\n' ' ')"
node -e 'const c=[];for(let i=0;i<1500;i++)c.push({type:"subtitle",file:`s${i}.png`,text:`第 ${i} 句字幕測試`});require("fs").writeFileSync("many.json",JSON.stringify({cards:c}))'
mkdir -p rk; node "$S/render.mjs" many.json rk >/dev/null 2>rk.err & RP=$!
found=0; for i in $(seq 1 100); do [ "$(chromes)" != 0 ] && found=1 && break; sleep 0.1; done
sleep 0.3; kill -TERM $RP 2>/dev/null; wait $RP; rc=$?; sleep 1
if [ $found = 1 ] && [ $rc -eq 143 ]; then
  [ "$(left)" = 0 ] && [ "$(chromes)" = 0 ] && grep -q "收到 SIGTERM" rk.err && ok "render.mjs 被 SIGTERM 中止 → 結束碼 143、Chrome 與設定檔都清掉" || bad "SIGTERM 收尾" "dirs=$(left) procs=$(chromes) stderr=$(cat rk.err)"
else bad "SIGTERM 收尾:沒有在 render 執行中送到訊號(found=$found rc=$rc),測試無法判定" ""; fi

# 8. compose.mjs 原聲精簡(cut 用 silence.sh 輸出)+ 拆句比例
mkdir -p job/2
cat > job/2/timeline.json <<EOF
{"mode":"original","work":"../work/2","source":"../../land.mp4","cut":$sil,
 "segments":[{"start":0.5,"end":2.9,"text":"第一段"},{"start":5.2,"end":9.5,"texts":["後面七個字吧","所以拆成兩句字幕"]}]}
EOF
node -e 'const fs=require("fs");const t=JSON.parse(fs.readFileSync("job/2/timeline.json","utf8"));fs.writeFileSync("job/2/hl.json",JSON.stringify({...t,headline:"標題"}))'
e="$(node "$S/compose.mjs" job/2/hl.json --dry-run 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'headline' && ok "原聲 headline 沒有 theme → dry-run 就結束碼 2" || bad "原聲 headline 沒有 theme" "$e"
node -e 'const fs=require("fs");const t=JSON.parse(fs.readFileSync("job/2/hl.json","utf8"));fs.writeFileSync("job/2/hl2.json",JSON.stringify({...t,theme:{bg:"#111111",bg2:"#222222",fg:"#ffffff",accent:"#ff8800",muted:"#999999",font:"x"}}))'
e="$(node "$S/compose.mjs" job/2/hl2.json --dry-run 2>&1)"; [ $? -eq 2 ] && echo "$e" | grep -q 'font' && ok "原聲 headline theme 多了欄位 → dry-run 就結束碼 2" || bad "theme 多餘欄位沒在 dry-run 擋" "$e"
c="$(node "$S/compose.mjs" job/2/timeline.json)"; rc=$?
node -e 'const c=JSON.parse(process.argv[1]);process.exit(Math.abs(c.sourceDuration-c.totalCut-c.actualDuration)<=0.5&&Math.abs(c.totalCut-1.8)<0.05?0:1)' "$c" 2>/dev/null \
  && ok "compose.mjs 精簡:來源 − 剪掉 = 成品長度(剪點各留 0.1 秒)" || bad "compose.mjs 精簡長度" "$c"
node -e '
const l=require("fs").readFileSync("job/2/subtitles.srt","utf8").trim().split(/\n\n/).map(b=>b.split("\n")[1].split(" --> ").map(t=>{const [h,m,s]=t.replace(",",".").split(":");return h*3600+m*60+Number(s)}));
// 5.2 → 3.4(前面剪掉 1.8);5.2–9.5 依字數 6:8 切分
const ok=l.length===3&&Math.abs(l[1][0]-3.4)<0.01&&Math.abs(l[1][1]-(3.4+4.3*6/14))<0.01&&Math.abs(l[2][1]-7.7)<0.01;process.exit(ok?0:1)' \
  && ok "原聲字幕重新對應時間、拆句依字數比例" || bad "原聲字幕對應" "$(cat job/2/subtitles.srt)"

# 9. 超過 60 秒 → 結束碼 5;verify.sh 對錯誤規格失敗
for i in 1 2 3 4 5 6 7; do echo "file '$T/land.mp4'"; done > l.txt
ffmpeg -hide_banner -loglevel error -y -f concat -safe 0 -i l.txt -c copy long.mp4
echo '{"mode":"original","work":"w3","source":"long.mp4"}' > long-tl.json
node "$S/compose.mjs" long-tl.json --dry-run >/dev/null 2>&1; [ $? -eq 5 ] && ok "compose.mjs 超過 60 秒 → 結束碼 5" || bad "compose.mjs 超過 60 秒"
echo '[]' > nb.json
v="$(bash "$S/verify.sh" bad.mp4 badchk --boxes nb.json --cover job/1/cover.png --scenes job/work/1/scenes.json)"; rc=$?
[ $rc -eq 1 ] && echo "$v" | grep -q '解析度 1280x720' && ok "verify.sh 錯誤規格 → 失敗" || bad "verify.sh 錯誤規格" "$v"
bash "$S/verify.sh" job/1/final.mp4 chk2 --boxes nope.json --cover job/1/cover.png --scenes job/work/1/scenes.json >/dev/null; [ $? -eq 1 ] && ok "verify.sh 找不到 boxes.json → 失敗" || bad "verify.sh 缺 boxes"

# 10. transcribe.sh(需要 whisper-cli 與模型)
if bash "$S/check.sh" --video >/dev/null 2>&1; then
  say -v Meijia -o speech.aiff "今天天氣很好,我們去公園散步。"
  ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=black:s=320x240:d=5 -i speech.aiff -c:v libx264 -c:a aac -shortest speech.mp4
  tr="$(bash "$S/transcribe.sh" speech.mp4 tr.json --lang zh)"
  node -e 'const j=JSON.parse(require("fs").readFileSync("tr.json","utf8"));const t=j.segments.map(s=>s.text).join("");process.exit(j.segments.length>0&&/公園|天氣/.test(t)?0:1)' \
    && ok "transcribe.sh 中文轉文字" || bad "transcribe.sh" "$tr $(cat tr.json 2>/dev/null)"
else skip "transcribe.sh(缺 whisper-cli 或模型檔)"; fi

echo "結果:$PASS 通過,$FAIL 失敗,$SKIP 略過"
[ $FAIL -eq 0 ] || exit 1
[ $SKIP -eq 0 ] || exit 3
