#!/bin/bash
# 用法:probe.sh <影片>
# 一行 JSON:{"duration":12.3,"width":1080,"height":1920,"rotation":0,"fps":30,"hasAudio":true,"orientation":"portrait"}
# width / height 已套用旋轉(顯示時的方向)。
source "$(dirname "$0")/_common.sh"
[ $# -eq 1 ] || die "用法:probe.sh <影片>"
need_file "$1"
ffprobe -v error -print_format json -show_format -show_streams "$1" | node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const j = JSON.parse(s);
  const v = j.streams.find(x => x.codec_type === "video");
  if (!v) { console.error("錯誤:沒有影像軌"); process.exit(1); }
  let rot = 0;
  for (const sd of v.side_data_list ?? []) if (typeof sd.rotation === "number") rot = sd.rotation;
  if (v.tags?.rotate) rot = Number(v.tags.rotate);
  rot = ((Math.round(rot) % 360) + 360) % 360;
  let w = v.width, h = v.height;
  if (rot === 90 || rot === 270) [w, h] = [h, w];
  const [n, d] = (v.avg_frame_rate || v.r_frame_rate || "0/1").split("/").map(Number);
  const fps = d ? Math.round((n / d) * 100) / 100 : 0;
  const duration = Number(j.format.duration ?? v.duration ?? 0);
  const out = { duration: Math.round(duration * 1000) / 1000, width: w, height: h, rotation: rot, fps,
    hasAudio: j.streams.some(x => x.codec_type === "audio"),
    orientation: h > w ? "portrait" : (h === w ? "square" : "landscape") };
  console.log(JSON.stringify(out));
});'
