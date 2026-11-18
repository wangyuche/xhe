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
{"cards":[
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
echo '{"cards":[{"type":"point","title":"x","image":"../cards.json"}]}' > esc.json
node "$S/render.mjs" esc.json r3 --asset-root assets >/dev/null 2>&1; [ $? -eq 1 ] && ok "render.mjs 擋 asset-root 外的圖" || bad "render.mjs asset-root 外"
echo '{"cards":[{"type":"point","title":"x","image":"https://example.com/a.png"}]}' > ext.json
node "$S/render.mjs" ext.json r3 --asset-root assets >/dev/null 2>&1; [ $? -eq 1 ] && ok "render.mjs 擋遠端圖片網址" || bad "render.mjs 遠端圖片"
ln -s /etc/hosts assets/link.png
echo '{"cards":[{"type":"point","title":"x","image":"link.png"}]}' > lnk.json
node "$S/render.mjs" lnk.json r3 --asset-root assets >/dev/null 2>&1; [ $? -eq 1 ] && ok "render.mjs 擋指到外面的 symlink" || bad "render.mjs symlink"

echo '{"cards":[{"type":"cover","file":"cv.png","tag":"repo","title":"漸層封面"}]}' > cv.json
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
fs.writeFileSync("job/1/timeline.json",JSON.stringify({mode:"narration",work:"../work/1",narration:n,
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

# 7b. 置頂鏡頭:第二版的設定(1000×1400 錄影、整支 fit crop、沒有 region)要被擋;設 region 後 UI 在字幕區上方
node -e '
const fs=require("fs");const n=JSON.parse(process.argv[1]).map((x,i)=>({...x,file:"../work/1/"+require("path").basename(x.file)}));
const mk=(sc,extra={})=>JSON.stringify({mode:"narration",work:"../work/1",narration:n,fit:"crop",...extra,scenes:sc});
fs.writeFileSync("job/1/v2.json",mk([{video:"../../app.mp4",sentences:[0]},{video:"../../app.mp4",in:1,sentences:[1]}]));
fs.writeFileSync("job/1/v3.json",mk([{video:"../../app.mp4",region:[250,40,745,830],sentences:[0]},{video:"../../app.mp4",in:1,region:[335,40,665,700],sentences:[1]}],{out:"v3"}));
fs.writeFileSync("job/1/bad-region.json",mk([{video:"../../app.mp4",region:[500,0,600,700],sentences:[0,1]}]));' "$tts"
e="$(node "$S/compose.mjs" job/1/v2.json --dry-run 2>&1)"; [ $? -eq 6 ] && echo "$e" | grep -q 'region' && ok "第二版設定(高錄影、沒有 region)→ 結束碼 6,提示設 region" || bad "第二版設定沒被擋" "$e"
node "$S/compose.mjs" job/1/bad-region.json --dry-run >/dev/null 2>&1; [ $? -eq 2 ] && ok "region 超出來源 → 結束碼 2" || bad "region 超出來源"
c3="$(node "$S/compose.mjs" job/1/v3.json)"; rc=$?
px() { ffmpeg -hide_banner -loglevel error -i "$1" -vf "crop=1:1:$2:$3,format=rgb24" -f rawvideo - | od -An -tu1 | tr -s ' ' | sed 's/^ //'; }
[ $rc -eq 0 ] && [ "$(jget "$c3" scenes.0.uiBottom)" -le 1280 ] && [ "$(jget "$c3" scenes.1.uiBottom)" -le 1280 ] && node -e 'const p=process.argv[1].trim().split(" ").map(Number);process.exit([11,18,32].every((v,i)=>Math.abs(p[i]-v)<=4)?0:1)' "$(px job/work/1/first-frame.png 540 1500)" \
  && ok "設 region 後置頂:UI 下緣 ≤ 1280、字幕區是底色" || bad "置頂鏡頭" "$c3 px=$(px job/work/1/first-frame.png 540 1500)"

# 8. compose.mjs 原聲精簡(cut 用 silence.sh 輸出)+ 拆句比例
mkdir -p job/2
cat > job/2/timeline.json <<EOF
{"mode":"original","work":"../work/2","source":"../../land.mp4","cut":$sil,
 "segments":[{"start":0.5,"end":2.9,"text":"第一段"},{"start":5.2,"end":9.5,"texts":["後面七個字吧","所以拆成兩句字幕"]}]}
EOF
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
