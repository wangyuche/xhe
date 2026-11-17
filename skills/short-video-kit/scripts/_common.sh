# short-video-kit 共用函式(由其他腳本 source)。macOS 內建 bash 3.2 相容。
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_TMP="${SHORT_VIDEO_KIT_TMP:-${TMPDIR:-/tmp}/short-video-kit}"
KIT_TMP="${KIT_TMP%/}"
CHROME="${CHROME_PATH:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
WHISPER_MODEL="${SHORT_VIDEO_WHISPER_MODEL:-$HOME/.cache/whisper/ggml-large-v3-turbo.bin}"

die() { echo "錯誤:$*" >&2; exit "${2:-1}"; }

need_file() { [ -f "$1" ] || die "找不到檔案:$1"; }

# 影片長度(秒,小數)
media_duration() {
  ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$1"
}

# 每次執行一個專屬暫存目錄,呼叫端要 trap 刪除
make_tmp() {
  mkdir -p "$KIT_TMP"
  mktemp -d "$KIT_TMP/${1:-run}.XXXXXX"
}
