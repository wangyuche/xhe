#!/bin/bash
# 用法:verify.sh <影片> <checks 目錄> --boxes <boxes.json> --cover <cover.png> --scenes <scenes.json>
# 檢查成品規格,並在 0%、25%、50%、75%、末 1 秒各擷一張圖到 <checks 目錄>;
# 另外每個鏡頭(compose.mjs 寫的 <work>/scenes.json)在中點與結尾前 0.2 秒各擷一張:scene-NN-mid.png、scene-NN-end.png。
# stdout 一行 JSON(含 ok 與 failures);任何一項不合格結束碼 1。
#   1080×1920、30 fps、h264 + yuv420p、aac 48000 Hz、faststart(moov 在 mdat 前)、長度 ≤ 60 秒
#   響度 −15 ~ −13 LUFS、true peak ≤ −1.0 dBTP
#   5 張擷圖平均亮度(Y)最小值 > 5
#   boxes.json 每個字幕框 x∈[60,930]、y∈[1300,1620](檔案找不到算失敗;空陣列表示沒有字幕)
#   cover.png 為 1080×1920
#   scenes.json 第一個鏡頭從 0 開始、鏡頭首尾相接、最後一個鏡頭結束在片長 ±0.1 秒(找不到算失敗)
source "$(dirname "$0")/_common.sh"
[ $# -ge 2 ] || die "用法:verify.sh <影片> <checks 目錄> --boxes <boxes.json> --cover <cover.png> --scenes <scenes.json>"
IN="$1"; CHK="$2"; shift 2; need_file "$IN"
BOXES=""; COVER=""; SCENES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --boxes) BOXES="$2"; shift 2 ;;
    --cover) COVER="$2"; shift 2 ;;
    --scenes) SCENES="$2"; shift 2 ;;
    *) die "未知參數:$1" ;;
  esac
done
[ -n "$BOXES" ] || die "缺 --boxes"
[ -n "$COVER" ] || die "缺 --cover"
[ -n "$SCENES" ] || die "缺 --scenes(compose.mjs 寫的 <work>/scenes.json)"
mkdir -p "$CHK"

PROBE="$(ffprobe -v error -print_format json -show_format -show_streams "$IN")"
DUR="$(media_duration "$IN")"
LOUD=""
if [ -n "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN")" ]; then
  LOUD="$( (ffmpeg -hide_banner -nostats -i "$IN" -filter_complex ebur128=peak=true -f null - 2>&1 || true) | sed -n '/Summary:/,$p')"
fi

# 擷圖與亮度
BRIGHT=""
i=0
for spec in "0:0.1" "25:" "50:" "75:" "end:"; do
  label="${spec%%:*}"
  case "$label" in
    0) t=0.1 ;;
    end) t="$(node -e "console.log(Math.max(0, $DUR - 1).toFixed(3))")" ;;
    *) t="$(node -e "console.log(($DUR * $label / 100).toFixed(3))")" ;;
  esac
  i=$((i + 1))
  f="$CHK/$i-${label}$( [ "$label" = end ] || echo pct ).png"
  ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$IN" -frames:v 1 "$f"
  y="$(ffmpeg -hide_banner -nostats -i "$f" -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 | sed -n 's/.*YAVG=\([0-9.]*\).*/\1/p' | head -1)"
  BRIGHT="$BRIGHT${BRIGHT:+,}{\"t\":$t,\"file\":\"$f\",\"yavg\":${y:-0}}"
done

# 逐鏡頭擷圖(中點、結尾前 0.2 秒)
SHOTS=""
if [ -f "$SCENES" ]; then
  while read -r n tm te; do
    for kind in mid end; do
      t="$tm"; [ "$kind" = end ] && t="$te"
      f="$CHK/scene-$n-$kind.png"
      ffmpeg -hide_banner -loglevel error -y -ss "$t" -i "$IN" -frames:v 1 "$f"
      SHOTS="$SHOTS${SHOTS:+,}\"$f\""
    done
  done < <(node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).forEach((s,i)=>console.log(String(i+1).padStart(2,"0"),((s.start+s.end)/2).toFixed(3),Math.max(s.start+0.05,s.end-0.2).toFixed(3)))' "$SCENES")
fi

COVER_DIM=""
if [ -f "$COVER" ]; then
  COVER_DIM="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$COVER")"
fi

PROBE="$PROBE" LOUD="$LOUD" BRIGHT="[$BRIGHT]" SHOTS="[$SHOTS]" SCENES="$SCENES" BOXES="$BOXES" COVER_DIM="$COVER_DIM" IN="$IN" node -e '
const fs = require("fs");
const p = JSON.parse(process.env.PROBE);
const v = p.streams.find(s => s.codec_type === "video") ?? {};
const a = p.streams.find(s => s.codec_type === "audio") ?? {};
const [fn, fd] = String(v.avg_frame_rate ?? "0/1").split("/").map(Number);
const fps = fd ? Math.round(fn / fd * 100) / 100 : 0;
// faststart:頂層 atom 中 moov 在 mdat 之前
let faststart = false;
{
  const fdh = fs.openSync(process.env.IN, "r"); const size = fs.fstatSync(fdh).size; const buf = Buffer.alloc(16);
  let off = 0; const order = [];
  while (off + 8 <= size && order.length < 50) {
    fs.readSync(fdh, buf, 0, 16, off);
    let len = buf.readUInt32BE(0); const type = buf.toString("latin1", 4, 8);
    if (len === 1) len = Number(buf.readBigUInt64BE(8)); else if (len === 0) len = size - off;
    if (len < 8) break;
    order.push(type); off += len;
  }
  fs.closeSync(fdh);
  faststart = order.indexOf("moov") !== -1 && order.indexOf("mdat") !== -1 && order.indexOf("moov") < order.indexOf("mdat");
}
const L = process.env.LOUD;
const num = (re) => { const m = L.match(re); return m ? Number(m[1]) : null; };
const lufs = num(/I:\s+(-?[\d.]+|-inf) LUFS/);
const truePeak = num(/True peak:\s+Peak:\s+(-?[\d.]+) dBFS/);
const bright = JSON.parse(process.env.BRIGHT);
const minBrightness = Math.min(...bright.map(b => b.yavg));
let subtitleBoxes = "ok"; let boxes = null;
try { boxes = JSON.parse(fs.readFileSync(process.env.BOXES, "utf8")); } catch { subtitleBoxes = "missing"; }
if (boxes) {
  const bad = boxes.filter(b => !(b.x >= 60 && b.x + b.w <= 930 && b.y >= 1300 && b.y + b.h <= 1620));
  if (bad.length) subtitleBoxes = `out-of-safe-area: ${bad.map(b => b.file).join(",")}`;
}
const duration = Math.round(Number(p.format.duration) * 1000) / 1000;
let scenes = null; let sceneCheck = "ok";
try { scenes = JSON.parse(fs.readFileSync(process.env.SCENES, "utf8")); } catch { sceneCheck = "missing"; }
if (scenes) {
  if (!Array.isArray(scenes) || !scenes.length) sceneCheck = "empty";
  else if (Math.abs(scenes[0].start) > 0.01 || scenes.some((s, i) => i > 0 && Math.abs(s.start - scenes[i - 1].end) > 0.05)
    || Math.abs(scenes[scenes.length - 1].end - duration) > 0.1) sceneCheck = "gap: 鏡頭沒有從 0 首尾相接到片長(scenes.json 不是這支成品的?)";
}
const out = {
  width: v.width, height: v.height, fps, vcodec: v.codec_name, pixFmt: v.pix_fmt,
  acodec: a.codec_name ?? null, sampleRate: a.sample_rate ? Number(a.sample_rate) : null, faststart, duration,
  lufs, truePeak, minBrightness, subtitles: boxes ? boxes.length : null, subtitleBoxes, scenes: scenes ? scenes.length : null, sceneCheck, cover: process.env.COVER_DIM || "missing",
};
const f = [];
if (out.width !== 1080 || out.height !== 1920) f.push(`解析度 ${out.width}x${out.height}`);
if (Math.abs(fps - 30) > 0.01) f.push(`fps ${fps}`);
if (out.vcodec !== "h264") f.push(`vcodec ${out.vcodec}`);
if (out.pixFmt !== "yuv420p") f.push(`pix_fmt ${out.pixFmt}`);
if (out.acodec !== "aac") f.push(`acodec ${out.acodec}`);
if (out.sampleRate !== 48000) f.push(`sampleRate ${out.sampleRate}`);
if (!faststart) f.push("沒有 faststart");
if (!(duration > 0 && duration <= 60.05)) f.push(`長度 ${duration}`);
if (lufs === null || lufs < -15 || lufs > -13) f.push(`響度 ${lufs} LUFS`);
if (truePeak === null || truePeak > -1.0) f.push(`true peak ${truePeak}`);
if (!(minBrightness > 5)) f.push(`擷圖太暗 ${minBrightness}`);
if (subtitleBoxes !== "ok") f.push(`字幕框 ${subtitleBoxes}`);
if (out.cover !== "1080x1920") f.push(`封面 ${out.cover}`);
if (sceneCheck !== "ok") f.push(`鏡頭表 ${sceneCheck}`);
out.checks = bright.map(b => b.file);
out.sceneChecks = JSON.parse(process.env.SHOTS);
out.ok = f.length === 0; if (f.length) out.failures = f;
console.log(JSON.stringify(out));
process.exit(out.ok ? 0 : 1);
'
