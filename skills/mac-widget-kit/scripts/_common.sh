# mac-widget-kit 共用函式(由其他腳本 source)
set -euo pipefail
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() { echo "錯誤:$*" >&2; exit 1; }

# 讀 widget.json 欄位
json_get() { plutil -extract "$2" raw -o - "$1/widget.json" 2>/dev/null; }

# cpu-mem → CpuMem
pascal() { echo "$1" | awk -F- '{for(i=1;i<=NF;i++) printf "%s%s", toupper(substr($i,1,1)), substr($i,2)}'; }

load_widget() {
  [ $# -ge 1 ] || die "缺少 widget 目錄參數"
  [ -d "$1" ] || die "目錄不存在:$1"
  WIDGET_DIR="$(cd "$1" && pwd)"
  [ -f "$WIDGET_DIR/widget.json" ] || die "找不到 $WIDGET_DIR/widget.json"
  [ "$(json_get "$WIDGET_DIR" kit || true)" = "mac-widget-kit" ] || die "widget.json 沒有 kit 標記,不是 mac-widget-kit 建立的目錄"
  WIDGET_NAME="$(json_get "$WIDGET_DIR" name)"
  [ -n "$WIDGET_NAME" ] || die "widget.json 的 name 是空的"
  APP_NAME="$(pascal "$WIDGET_NAME")"
  APP_PATH="$WIDGET_DIR/build/$APP_NAME.app"
  APP_BIN="$APP_PATH/Contents/MacOS/$APP_NAME"
  LABEL="com.widget.$WIDGET_NAME"
}
