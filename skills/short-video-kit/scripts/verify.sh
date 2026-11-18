#!/bin/bash
# 用法:verify.sh <影片> <checks 目錄> --boxes <boxes.json> --cover <cover.png>
# 檢查成品規格,並在 0%、25%、50%、75%、末 1 秒各擷一張圖到 <checks 目錄>。
# stdout 一行 JSON(含 ok 與 failures);任何一項不合格結束碼 1。
#   1080×1920、30 fps、h264 + yuv420p、aac 48000 Hz、faststart(moov 在 mdat 前)、長度 ≤ 60 秒
#   響度 −15 ~ −13 LUFS、true peak ≤ −1.0 dBTP
#   5 張擷圖平均亮度(Y)最小值 > 5
#   boxes.json 每個字幕框 x∈[60,930]、y∈[1300,1620](檔案找不到算失敗;空陣列表示沒有字幕)
#   cover.png 為 1080×1920
source "$(dirname "$0")/_common.sh"
[ $# -ge 2 ] || die "用法:verify.sh <影片> <checks 目錄> --boxes <boxes.json> --cover <cover.png>"
IN="$1"; CHK="$2"; shift 2; need_file "$IN"
BOXES=""; COVER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --boxes) BOXES="$2"; shift 2 ;;
    --cover) COVER="$2"; shift 2 ;;
    *) die "未知參數:$1" ;;
  esac
done
[ -n "$BOXES" ] || die "缺 --boxes"
[ -n "$COVER" ] || die "缺 --cover"
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

COVER_DIM=""
if [ -f "$COVER" ]; then
  COVER_DIM="$(ffprobe -v error -select_streams v:0 -show_entries stream=width,height -of csv=s=x:p=0 "$COVER")"
fi

PROBE="$PROBE" LOUD="$LOUD" BRIGHT="[$BRIGHT]" BOXES="$BOXES" COVER_DIM="$COVER_DIM" IN="$IN" node -e '
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
const out = {
  width: v.width, height: v.height, fps, vcodec: v.codec_name, pixFmt: v.pix_fmt,
  acodec: a.codec_name ?? null, sampleRate: a.sample_rate ? Number(a.sample_rate) : null, faststart, duration,
  lufs, truePeak, minBrightness, subtitles: boxes ? boxes.length : null, subtitleBoxes, cover: process.env.COVER_DIM || "missing",
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
out.checks = bright.map(b => b.file);
out.ok = f.length === 0; if (f.length) out.failures = f;
console.log(JSON.stringify(out));
process.exit(out.ok ? 0 : 1);
'
