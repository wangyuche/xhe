#!/bin/bash
# 用法:serve.sh <name> <dir> <起始埠> [--health <路徑>] [--timeout <秒>] [--env K=V]... -- <指令...>
# 在新的程序群組背景啟動指令,等到 HTTP 可回應才返回。
source "$(dirname "$0")/_common.sh"

[ $# -ge 4 ] || die "用法:serve.sh <name> <dir> <起始埠> [--health <路徑>] [--timeout <秒>] [--env K=V]... -- <指令...>"
NAME="$1"; DIR="$2"; START_PORT="$3"; shift 3
check_name "$NAME"
[ -d "$DIR" ] || die "目錄不存在:$DIR"
case "$START_PORT" in *[!0-9]*|'') die "起始埠必須是數字:$START_PORT" ;; esac

HEALTH="/"; TIMEOUT=90; ENVS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --health) HEALTH="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --env) case "$2" in *=*) ENVS+=("$2") ;; *) die "--env 需要 K=V:$2" ;; esac; shift 2 ;;
    --) shift; break ;;
    *) die "未知參數:$1(指令前要加 --)" ;;
  esac
done
[ $# -ge 1 ] || die "缺少要執行的指令(放在 -- 之後)"

ND="$(name_dir "$NAME")"; mkdir -p "$ND"
STATE="$ND/serve.state"
if [ -f "$STATE" ]; then
  # shellcheck disable=SC1090
  OLD_PGID="$(sed -n 's/^PGID=//p' "$STATE")"
  if [ -n "$OLD_PGID" ] && pgid_alive "$OLD_PGID"; then
    die "同名服務 $NAME 已在執行(pgid=$OLD_PGID),先 stop.sh $NAME"
  fi
  rm -f "$STATE"
fi

PORT="$(find_free_port "$START_PORT")" || die "從 $START_PORT 起 20 個埠都被占用"

CMD=()
for a in "$@"; do CMD+=("${a//\{port\}/$PORT}"); done

LOG="$ND/server.log"; : > "$LOG"
ABS_DIR="$(cd "$DIR" && pwd)"

# set -m:背景工作自成一個程序群組(pgid = pid),stop.sh 才能整組停掉
set -m
(
  cd "$ABS_DIR"
  if [ ${#ENVS[@]} -gt 0 ]; then
    exec env "${ENVS[@]}" PORT="$PORT" "${CMD[@]}"
  else
    exec env PORT="$PORT" "${CMD[@]}"
  fi
) >>"$LOG" 2>&1 < /dev/null &
PID=$!
set +m
PGID="$(ps -o pgid= -p "$PID" | tr -d ' ')"
[ -n "$PGID" ] || PGID="$PID"
printf 'PGID=%s\nPORT=%s\nPID=%s\nLOG=%s\n' "$PGID" "$PORT" "$PID" "$LOG" > "$STATE"

kill_group() {
  kill -TERM -- "-$PGID" 2>/dev/null || true
  local i=0
  while pgid_alive "$PGID" && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done
  pgid_alive "$PGID" && kill -KILL -- "-$PGID" 2>/dev/null || true
  rm -f "$STATE"
}

URL="http://127.0.0.1:$PORT$HEALTH"
DEADLINE=$(( $(date +%s) + TIMEOUT ))
while :; do
  if ! kill -0 "$PID" 2>/dev/null; then
    echo "錯誤:指令提早結束。server.log 最後 30 行:" >&2
    tail -n 30 "$LOG" >&2
    kill_group; exit 1
  fi
  CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$URL" 2>/dev/null || true)"
  if [ -n "$CODE" ] && [ "$CODE" != "000" ] && [ "$CODE" -lt 500 ]; then break; fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "錯誤:${TIMEOUT} 秒內 $URL 沒有回應(最後狀態 ${CODE:-無})。server.log 最後 30 行:" >&2
    tail -n 30 "$LOG" >&2
    kill_group; exit 1
  fi
  sleep 1
done

echo "url=http://localhost:$PORT port=$PORT pgid=$PGID log=$LOG"
