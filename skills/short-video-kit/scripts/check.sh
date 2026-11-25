#!/bin/bash
# 用法:check.sh [--video] [--url] [--no-say]
# --no-say:不檢查 macOS say 的 Meijia 聲音(motion-video-kit 用 Qwen3-TTS 旁白時)
# 檢查工具是否齊全。每項印一行 ok / missing;缺少時結束碼 3 並印安裝指令。
source "$(dirname "$0")/_common.sh"

VIDEO=0; URL=0; SAY=1
for a in "$@"; do
  case "$a" in
    --video) VIDEO=1 ;;
    --url) URL=1 ;;
    --no-say) SAY=0 ;;
    *) die "未知參數:$a(只接受 --video、--url、--no-say)" ;;
  esac
done

MISSING=(); HINTS=()
ok() { echo "ok      $1"; }
miss() { echo "missing $1"; MISSING+=("$1"); HINTS+=("$2"); }

for t in ffmpeg ffprobe; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t ($(command -v "$t"))"; else miss "$t" "brew install ffmpeg"; fi
done
if command -v node >/dev/null 2>&1; then
  NV="$(node -v)"; MAJOR="${NV#v}"; MAJOR="${MAJOR%%.*}"
  if [ "$MAJOR" -ge 22 ]; then ok "node $NV"; else miss "node >= 22(目前 $NV)" "brew install node"; fi
else miss "node" "brew install node"; fi
if [ -x "$CHROME" ]; then ok "chrome ($CHROME)"; else miss "Google Chrome" "安裝 Google Chrome,或設定 CHROME_PATH"; fi
if [ $SAY -eq 0 ]; then echo "skip    say(--no-say)"
elif say -v '?' 2>/dev/null | grep -q '^Meijia '; then ok "say -v Meijia"; else
  miss "say 聲音 Meijia" "系統設定 → 輔助使用 → 朗讀內容 → 系統聲音 → 管理聲音,加入「美佳」"; fi

if [ $VIDEO -eq 1 ]; then
  if command -v whisper-cli >/dev/null 2>&1; then ok "whisper-cli ($(command -v whisper-cli))"; else miss "whisper-cli" "brew install whisper-cpp"; fi
  if [ -s "$WHISPER_MODEL" ]; then ok "whisper 模型 ($WHISPER_MODEL)"; else
    miss "whisper 模型 $WHISPER_MODEL" "mkdir -p \"$(dirname "$WHISPER_MODEL")\" && curl -L -o \"$WHISPER_MODEL\" https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$(basename "$WHISPER_MODEL")"; fi
fi
if [ $URL -eq 1 ]; then
  if command -v yt-dlp >/dev/null 2>&1; then ok "yt-dlp ($(command -v yt-dlp))"; else miss "yt-dlp" "brew install yt-dlp"; fi
fi

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "安裝指令:"
  i=0; while [ $i -lt ${#HINTS[@]} ]; do echo "  ${HINTS[$i]}"; i=$((i + 1)); done
  exit 3
fi
echo "all-ok"
