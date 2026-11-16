#!/bin/bash
# 用法:stop.sh <name>
# 停掉 serve.sh 啟動的整個程序群組,確認埠已釋放。
source "$(dirname "$0")/_common.sh"

[ $# -eq 1 ] || die "用法:stop.sh <name>"
NAME="$1"; check_name "$NAME"
STATE="$(name_dir "$NAME")/serve.state"

if [ ! -f "$STATE" ]; then echo "not-running"; exit 0; fi
PGID="$(sed -n 's/^PGID=//p' "$STATE")"
PORT="$(sed -n 's/^PORT=//p' "$STATE")"

if [ -z "$PGID" ] || ! pgid_alive "$PGID"; then
  rm -f "$STATE"; echo "not-running"; exit 0
fi

kill -TERM -- "-$PGID" 2>/dev/null || true
i=0
while pgid_alive "$PGID" && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
if pgid_alive "$PGID"; then
  kill -KILL -- "-$PGID" 2>/dev/null || true
  sleep 0.5
fi

# 埠釋放可能稍慢,最多等 3 秒
i=0
while port_busy "$PORT" && [ $i -lt 6 ]; do sleep 0.5; i=$((i + 1)); done
if port_busy "$PORT"; then
  echo "錯誤:程序群組已停,但埠 $PORT 仍被占用:" >&2
  lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >&2 || true
  exit 1
fi
rm -f "$STATE"
echo "stopped port=$PORT"
