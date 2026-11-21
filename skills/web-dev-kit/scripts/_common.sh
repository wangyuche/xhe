# web-dev-kit 共用函式(由其他腳本 source)。macOS 內建 bash 3.2 相容。
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT_TMP="${WEB_DEV_KIT_TMP:-${TMPDIR:-/tmp}/web-dev-kit}"
KIT_TMP="${KIT_TMP%/}"

die() { echo "錯誤:$1" >&2; exit "${2:-1}"; }

check_name() {
  [ -n "${1:-}" ] || die "缺少 <name>"
  case "$1" in
    *[!a-z0-9-]*) die "<name> 只能是小寫英文、數字與連字號:$1" ;;
  esac
}

name_dir() { echo "$KIT_TMP/$1"; }

# 埠是否有程序在 LISTEN
port_busy() { lsof -nP -iTCP:"$1" -sTCP:LISTEN -t >/dev/null 2>&1; }

# 從起始埠往上找可用埠(最多 20 個)
find_free_port() {
  local p="$1" i=0
  while [ $i -lt 20 ]; do
    if ! port_busy "$p"; then echo "$p"; return 0; fi
    p=$((p + 1)); i=$((i + 1))
  done
  return 1
}

# 程序群組是否還有成員
pgid_alive() { [ -n "$(ps -A -o pgid= | awk -v g="$1" '$1==g' | head -1)" ]; }
