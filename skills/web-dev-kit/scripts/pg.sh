#!/bin/bash
# 用法:pg.sh up <專案名> | pg.sh down <專案名> | pg.sh schema <專案名> <表>
# 本機開發用 PostgreSQL 容器 dev-<專案名>-pg(postgres:17,帳密 dev/devpass,資料庫 app)。
# down 只 stop,不刪容器與資料。Docker 沒開:結束碼 3。
source "$(dirname "$0")/_common.sh"

[ $# -ge 2 ] || die "用法:pg.sh up|down <專案名> | pg.sh schema <專案名> <表>"
CMD="$1"; PROJ="$2"
check_name "$PROJ"
C="dev-$PROJ-pg"
IMAGE="postgres:17"

docker info >/dev/null 2>&1 || die "Docker 沒有在執行" 3

exists() { [ -n "$(docker ps -a --filter "name=^/${C}\$" --format '{{.Names}}')" ]; }
running() { [ -n "$(docker ps --filter "name=^/${C}\$" --format '{{.Names}}')" ]; }
host_port() { docker port "$C" 5432/tcp 2>/dev/null | head -1 | sed 's/.*://'; }

case "$CMD" in
  up)
    if exists; then
      running || docker start "$C" >/dev/null
    else
      PORT="$(find_free_port 5432)" || die "5432 起 20 個埠都被占用"
      docker run -d --name "$C" \
        -e POSTGRES_USER=dev -e POSTGRES_PASSWORD=devpass -e POSTGRES_DB=app \
        -p "127.0.0.1:$PORT:5432" "$IMAGE" >/dev/null
    fi
    i=0
    until docker exec "$C" pg_isready -U dev -d app >/dev/null 2>&1; do
      i=$((i + 1)); [ $i -lt 60 ] || die "PostgreSQL 60 秒內沒有就緒"
      sleep 1
    done
    echo "DATABASE_URL=postgres://dev:devpass@127.0.0.1:$(host_port)/app?sslmode=disable"
    ;;
  down)
    if running; then docker stop "$C" >/dev/null; fi
    echo "stopped container=$C"
    ;;
  schema)
    [ $# -eq 3 ] || die "用法:pg.sh schema <專案名> <表>"
    running || die "容器 $C 沒有在執行,先 pg.sh up $PROJ"
    case "$3" in *[!a-zA-Z0-9_.]*) die "表名只能是英數、底線、點:$3" ;; esac
    docker exec "$C" psql -U dev -d app -c "\\d $3"
    ;;
  *) die "未知子命令:$CMD" ;;
esac
