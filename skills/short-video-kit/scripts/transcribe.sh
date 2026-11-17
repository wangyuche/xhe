#!/bin/bash
# 用法:transcribe.sh <影片> <輸出.json> [--lang auto|zh|en|ja…]
# 抽 16 kHz 單聲道 → whisper-cli → {"lang":"zh","segments":[{"start":0.0,"end":2.4,"text":"…"}]}
# 中文時用繁體提示詞引導;沒有音軌結束碼 3;缺 whisper-cli 或模型結束碼 3。
source "$(dirname "$0")/_common.sh"
[ $# -ge 2 ] || die "用法:transcribe.sh <影片> <輸出.json> [--lang auto]"
IN="$1"; OUT="$2"; shift 2; need_file "$IN"
LANG_=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --lang) LANG_="$2"; shift 2 ;;
    *) die "未知參數:$1" ;;
  esac
done
command -v whisper-cli >/dev/null 2>&1 || die "缺 whisper-cli(brew install whisper-cpp)" 3
[ -s "$WHISPER_MODEL" ] || die "缺模型檔 $WHISPER_MODEL(見 check.sh --video)" 3
if [ -z "$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$IN")" ]; then
  die "沒有音軌,無法轉文字" 3
fi
TMP="$(make_tmp transcribe)"; trap 'rm -rf "$TMP"' EXIT
ffmpeg -hide_banner -loglevel error -y -i "$IN" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$TMP/a.wav"

ARGS=(-m "$WHISPER_MODEL" -f "$TMP/a.wav" -l "$LANG_" -oj -of "$TMP/out" -np)
case "$LANG_" in zh|auto) ARGS+=(--prompt "以下是繁體中文的逐字稿,包含標點符號。") ;; esac
whisper-cli "${ARGS[@]}" >"$TMP/log" 2>&1 || { tail -n 20 "$TMP/log" >&2; die "whisper-cli 失敗"; }

mkdir -p "$(dirname "$OUT")"
node -e '
const fs = require("fs");
const j = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
const segs = (j.transcription ?? []).map(t => ({
  start: Math.round(t.offsets.from) / 1000,
  end: Math.round(t.offsets.to) / 1000,
  text: String(t.text ?? "").trim(),
})).filter(s => s.text && s.end > s.start);
const out = { lang: j.result?.language ?? process.argv[3], segments: segs };
fs.writeFileSync(process.argv[2], JSON.stringify(out, null, 1));
console.log(JSON.stringify({ lang: out.lang, segments: segs.length, chars: segs.reduce((n, s) => n + s.text.length, 0), out: process.argv[2] }));
' "$TMP/out.json" "$OUT" "$LANG_"
