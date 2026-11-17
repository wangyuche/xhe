#!/bin/bash
# 用法:tts.sh <句子檔> <輸出目錄> [--voice Meijia] [--rate 190]
# 句子檔每行一句(空行略過)→ <輸出目錄>/001.m4a …(AAC 48 kHz 單聲道,去掉頭尾靜音)
# stdout 一行 JSON:[{"i":0,"text":"…","file":"<絕對路徑>","duration":1.234}],另印總長到 stderr。
source "$(dirname "$0")/_common.sh"
[ $# -ge 2 ] || die "用法:tts.sh <句子檔> <輸出目錄> [--voice Meijia] [--rate 190]"
SRC="$1"; OUT="$2"; shift 2; need_file "$SRC"
VOICE=Meijia; RATE=190
while [ $# -gt 0 ]; do
  case "$1" in
    --voice) VOICE="$2"; shift 2 ;;
    --rate) RATE="$2"; shift 2 ;;
    *) die "未知參數:$1" ;;
  esac
done
case "$RATE" in *[!0-9]*|'') die "--rate 必須是整數" ;; esac
say -v '?' | grep -q "^$VOICE " || die "找不到聲音 $VOICE(say -v '?' 查可用聲音)"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
TMP="$(make_tmp tts)"; trap 'rm -rf "$TMP"' EXIT

i=0; JSON="["
while IFS= read -r line || [ -n "$line" ]; do
  text="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$text" ] || continue
  n="$(printf '%03d' $((i + 1)))"
  printf '%s' "$text" > "$TMP/$n.txt"
  say -v "$VOICE" -r "$RATE" -f "$TMP/$n.txt" -o "$TMP/$n.aiff"
  # 去掉頭尾靜音(-50 dB),讓字幕時間與聲音貼齊
  ffmpeg -hide_banner -loglevel error -y -i "$TMP/$n.aiff" \
    -af "silenceremove=start_periods=1:start_threshold=-50dB,areverse,silenceremove=start_periods=1:start_threshold=-50dB,areverse" \
    -ar 48000 -ac 1 -c:a aac -b:a 128k "$OUT/$n.m4a"
  d="$(media_duration "$OUT/$n.m4a")"
  esc="$(printf '%s' "$text" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.stringify(s)))')"
  [ $i -gt 0 ] && JSON="$JSON,"
  JSON="$JSON{\"i\":$i,\"text\":$esc,\"file\":\"$OUT/$n.m4a\",\"duration\":$(printf '%.3f' "$d")}"
  i=$((i + 1))
done < "$SRC"
JSON="$JSON]"
[ $i -gt 0 ] || die "句子檔沒有任何句子"
echo "$JSON"
echo "$JSON" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const a=JSON.parse(s);console.error(`句數 ${a.length},總長 ${a.reduce((t,x)=>t+x.duration,0).toFixed(2)} 秒`)})'
