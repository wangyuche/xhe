#!/bin/bash
# 用法:silence.sh <影片> [--min 0.5] [--db -35]
# 一行 JSON:[{"start":1.2,"end":2.05},...](秒)。沒有音軌結束碼 3。
source "$(dirname "$0")/_common.sh"
[ $# -ge 1 ] || die "用法:silence.sh <影片> [--min 0.5] [--db -35]"
IN="$1"; shift; need_file "$IN"
MIN=0.5; DB=-35
while [ $# -gt 0 ]; do
  case "$1" in
    --min) MIN="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    *) die "未知參數:$1" ;;
  esac
done
if [ -z "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN")" ]; then
  die "沒有音軌,無法偵測停頓" 3
fi
DUR="$(media_duration "$IN")"
ffmpeg -hide_banner -nostats -i "$IN" -vn -af "silencedetect=n=${DB}dB:d=${MIN}" -f null - 2>&1 \
  | DUR="$DUR" node -e '
let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
  const out = []; let cur = null;
  for (const line of s.split("\n")) {
    let m;
    if ((m = line.match(/silence_start: (-?[\d.]+)/))) cur = Math.max(0, Number(m[1]));
    else if ((m = line.match(/silence_end: ([\d.]+)/)) && cur !== null) { out.push({ start: cur, end: Number(m[1]) }); cur = null; }
  }
  if (cur !== null) out.push({ start: cur, end: Number(process.env.DUR) });
  const r = x => Math.round(x * 1000) / 1000;
  console.log(JSON.stringify(out.map(x => ({ start: r(x.start), end: r(x.end) }))));
});'
