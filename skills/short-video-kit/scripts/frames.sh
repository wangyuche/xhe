#!/bin/bash
# 用法:frames.sh <影格目錄> <名稱> <輸出.mp4> [--fps 24] [--frames N]
# 把 game-art-kit comfy.mjs run 下載的 <名稱>-1.png … <名稱>-N.png(ComfyUI 影片骨架逐格輸出)組成 H.264 MP4。
# 檢查:至少 2 格、編號從 1 連續、所有格尺寸一致(寬高偶數)。不刪影格(跟著 work/ 一起刪)。
# --frames N:只取 1..N(同名重跑時 comfy.mjs 只覆寫 1..N,上一輪多出來的格數會留著;給 N 就忽略它們)。缺任何一格結束碼 2。
# 印一行 JSON:{"frames":121,"fps":24,"duration":5.042,"width":704,"height":1280,"file":"…"}
# 結束碼:0 成功、1 ffmpeg 失敗、2 用法或影格不合格。
source "$(dirname "$0")/_common.sh"
usage="用法:frames.sh <影格目錄> <名稱> <輸出.mp4> [--fps 24] [--frames N]"
[ $# -ge 3 ] || die "$usage" 2
dir="$1"; name="$2"; out="$3"; shift 3
fps=24; want=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fps) fps="${2:-}"; shift 2 || die "$usage" 2 ;;
    --frames) want="${2:-}"; shift 2 || die "$usage" 2 ;;
    *) die "$usage" 2 ;;
  esac
done
[[ "$fps" =~ ^[0-9]+$ ]] && [ "$fps" -ge 1 ] && [ "$fps" -le 60 ] || die "--fps 要是 1–60 的整數" 2
[ -d "$dir" ] || die "找不到影格目錄:$dir" 2
case "$dir" in *%*) die "影格目錄路徑不能有 %(ffmpeg 會當成編號樣式):$dir" 2 ;; esac
case "$name" in *[!A-Za-z0-9_.-]*|'') die "名稱只能用英數、底線、點、連字號:$name" 2 ;; esac

# 數連續編號;中間缺號或之後還有更大的編號都算不合格
n=0
while [ -f "$dir/$name-$((n + 1)).png" ]; do n=$((n + 1)); done
[ "$n" -ge 2 ] || die "找不到 $dir/$name-1.png、$name-2.png…(至少要 2 格)" 2
if [ -n "$want" ]; then
  [[ "$want" =~ ^[0-9]+$ ]] && [ "$want" -ge 2 ] || die "--frames 要是 ≥ 2 的整數" 2
  [ "$n" -ge "$want" ] || die "只有 $name-1..$n 連續,少於 --frames $want" 2
  n="$want"
else
# 只算 <名稱>-<數字>.png(重出用的 <名稱>-r2-1.png 不算)
extra=$(find "$dir" -maxdepth 1 -name "$name-*.png" -print | sed 's|.*/||' | grep -cE "^$(printf '%s' "$name" | sed 's/[.]/\\./g')-[0-9]+\.png$" || true)
[ "$extra" -eq "$n" ] || die "影格編號不連續:找到 $extra 個 $name-<數字>.png,但只有 1–$n 連續(同名重跑留下的舊格數:加 --frames <這次的格數>)" 2
fi

# 尺寸一致(用 ffprobe 一次讀全部會很慢,逐格讀 PNG 檔頭)
size=$(node -e '
const fs = require("fs"); const [dir, name, n] = process.argv.slice(1); let first = null;
for (let i = 1; i <= Number(n); i++) {
  const b = fs.readFileSync(`${dir}/${name}-${i}.png`);
  if (b.length < 24 || b.toString("ascii", 1, 4) !== "PNG") { console.error(`錯誤:${name}-${i}.png 不是 PNG`); process.exit(2); }
  const s = `${b.readUInt32BE(16)}x${b.readUInt32BE(20)}`;
  if (first === null) first = s; else if (s !== first) { console.error(`錯誤:${name}-${i}.png 尺寸 ${s} 與第 1 格 ${first} 不同`); process.exit(2); }
}
console.log(first);' "$dir" "$name" "$n") || exit 2
w="${size%x*}"; h="${size#*x}"
[ $((w % 2)) -eq 0 ] && [ $((h % 2)) -eq 0 ] || die "影格寬高要是偶數(H.264 yuv420p):$size" 2

mkdir -p "$(dirname "$out")"
ffmpeg -hide_banner -loglevel error -y -framerate "$fps" -start_number 1 -i "$dir/$name-%d.png" -frames:v "$n" \
  -c:v libx264 -preset medium -crf 16 -pix_fmt yuv420p -movflags +faststart "$out" || die "ffmpeg 組影片失敗" 1
node -e 'const [n, fps, w, h, f] = process.argv.slice(1);
console.log(JSON.stringify({ frames: +n, fps: +fps, duration: Math.round(n / fps * 1000) / 1000, width: +w, height: +h, file: f }));' "$n" "$fps" "$w" "$h" "$out"
