#!/bin/bash
# 用法:compose.sh build|up|down|ps|logs -p <專案名> [-f <compose 檔>] [選項] [<服務>...]
#   build [<服務>...]                     docker compose build
#   up [--build] [--timeout 180]          up -d,等所有有 healthcheck 的服務 healthy → 每個對外埠印 url=… port=… service=…
#   down [--volumes] [--images]           預設保留 volume(--volumes 才刪)、保留映像(--images 刪本專案建的映像)
#   ps                                    docker compose ps -a
#   logs <服務> [--tail 200]              不 follow
# 一律帶 -p <專案名>,只動這個 compose 專案。專案名不能等於 compose 預設專案名(目錄名、COMPOSE_PROJECT_NAME、
# compose 檔的 name:),以免動到使用者自己的專案;確定要用時加 --allow-default。
# 結束碼:0 成功;1 參數錯誤、compose 失敗、unhealthy 或逾時;3 Docker 沒開;4 對外埠被占用(不會停任何容器)。
source "$(dirname "$0")/_common.sh"

USAGE="用法:compose.sh build|up|down|ps|logs -p <專案名> [-f <compose 檔>] [--allow-default] [選項] [<服務>...]"
[ $# -ge 1 ] || die "$USAGE"
CMD="$1"; shift
case "$CMD" in build|up|down|ps|logs) ;; *) die "未知子命令:${CMD}。$USAGE" ;; esac

PROJ=""; FILE=""; ALLOW_DEFAULT=0; BUILD=0; TIMEOUT=180; VOLUMES=0; IMAGES=0; TAIL=200; SERVICES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project) [ $# -ge 2 ] || die "$1 需要專案名"; PROJ="$2"; shift 2 ;;
    -f|--file) [ $# -ge 2 ] || die "$1 需要檔案路徑"; FILE="$2"; shift 2 ;;
    --allow-default) ALLOW_DEFAULT=1; shift ;;
    --build) [ "$CMD" = up ] || die "--build 只用在 up"; BUILD=1; shift ;;
    --timeout) [ "$CMD" = up ] || die "--timeout 只用在 up"; [ $# -ge 2 ] || die "--timeout 缺值"; TIMEOUT="$2"; shift 2 ;;
    --volumes) [ "$CMD" = down ] || die "--volumes 只用在 down"; VOLUMES=1; shift ;;
    --images) [ "$CMD" = down ] || die "--images 只用在 down"; IMAGES=1; shift ;;
    --tail) [ "$CMD" = logs ] || die "--tail 只用在 logs"; [ $# -ge 2 ] || die "--tail 缺值"; TAIL="$2"; shift 2 ;;
    -*) die "未知參數:$1" ;;
    *) SERVICES+=("$1"); shift ;;
  esac
done

[ -n "$PROJ" ] || die "缺少 -p <專案名>(必填,避免動到其他 compose 專案)"
check_name "$PROJ"
case "$TIMEOUT" in *[!0-9]*|'') die "--timeout 必須是秒數:$TIMEOUT" ;; esac
case "$TAIL" in *[!0-9]*|'') die "--tail 必須是數字:$TAIL" ;; esac
case "$CMD" in
  logs) [ ${#SERVICES[@]} -eq 1 ] || die "用法:compose.sh logs -p <專案名> <服務> [--tail 200]" ;;
  up|down|ps) [ ${#SERVICES[@]} -eq 0 ] || die "$CMD 不接受服務名稱:${SERVICES[*]}" ;;
esac

# compose 檔:-f 指定,否則找目前目錄的預設檔名
if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || die "compose 檔不存在:$FILE"
else
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
    [ -f "$f" ] && { FILE="$f"; break; }
  done
fi
if [ -n "$FILE" ]; then
  FILE="$(cd "$(dirname "$FILE")" && pwd)/$(basename "$FILE")"
  PROJ_DIR="$(dirname "$FILE")"
else
  case "$CMD" in build|up) die "找不到 compose 檔(compose.yaml / docker-compose.yml),用 -f 指定" ;; esac
  PROJ_DIR="$(pwd)"
fi

# 拒絕 compose 預設專案名:不加 -p 時 docker compose 會用的名稱
if [ "$ALLOW_DEFAULT" = 0 ]; then
  base="$(basename "$PROJ_DIR" | tr 'A-Z' 'a-z')"
  defaults="$(printf '%s\n' "$base" | sed 's/[^a-z0-9_-]//g')
$(printf '%s\n' "$base" | sed 's/[^a-z0-9-]/-/g')
${COMPOSE_PROJECT_NAME:-}"
  # 專案目錄的 .env 也能設 COMPOSE_PROJECT_NAME(docker compose 會自動讀)
  [ -f "$PROJ_DIR/.env" ] && defaults="$defaults
$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}COMPOSE_PROJECT_NAME[[:space:]]*=[[:space:]]*["'\'']\{0,1\}\([^"'\'' #]*\).*/\2/p' "$PROJ_DIR/.env" | tail -1)"
  [ -n "$FILE" ] && defaults="$defaults
$(sed -n 's/^name:[[:space:]]*["'\'']\{0,1\}\([^"'\'' #]*\).*/\1/p' "$FILE" | head -1)"
  if printf '%s\n' "$defaults" | grep -qxF -- "$PROJ"; then
    die "專案名 $PROJ 和這個目錄的 compose 預設專案名相同,可能是使用者自己的專案。換一個名稱(例如 dev-$PROJ),確定要用時加 --allow-default"
  fi
fi

command -v docker >/dev/null 2>&1 || die "找不到 docker 指令" 3
docker info >/dev/null 2>&1 || die "Docker 沒有在執行" 3
docker compose version >/dev/null 2>&1 || die "沒有 docker compose(v2 外掛)" 3

dc() {
  if [ -n "$FILE" ]; then docker compose -p "$PROJ" -f "$FILE" "$@"; else docker compose -p "$PROJ" "$@"; fi
}

# compose 檔裡的對外埠:每行「服務 容器埠 主機埠 主機IP」
published_ports() {
  dc config --format json | python3 -c '
import json, sys
cfg = json.load(sys.stdin)
for name, svc in sorted((cfg.get("services") or {}).items()):
    for p in svc.get("ports") or []:
        print(name, p.get("target", ""), p.get("published", "") or "-", p.get("host_ip", "") or "-")
'
}

# 這個專案已經占用的主機埠(重複 up 時不算衝突)
# 服務沒在跑(例如一次性服務已結束)時 docker compose port 會失敗:回空字串,不讓 pipefail 中斷
own_port() { dc port "$1" "$2" </dev/null 2>/dev/null | head -1 | sed 's/.*://' || true; }

dump_failure() {
  echo "--- docker compose ps -a(專案 $PROJ)" >&2
  dc ps -a >&2 || true
  echo "--- docker compose logs --tail 50" >&2
  dc logs --no-color --tail 50 >&2 || true
}

case "$CMD" in
  build)
    if [ ${#SERVICES[@]} -gt 0 ]; then dc build "${SERVICES[@]}"; else dc build; fi
    echo "built project=$PROJ"
    ;;

  up)
    PORTS="$(published_ports)" || die "docker compose config 失敗"
    busy=0
    while read -r svc target pub hip; do
      [ -n "$svc" ] || continue
      case "$hip" in -|0.0.0.0|::) echo "警告:$svc 的埠 $pub 綁在所有網路介面(區網可連),建議寫成 \"127.0.0.1:$pub:$target\"" >&2 ;; esac
      [ "$pub" != "-" ] || continue
      case "$pub" in *[!0-9]*) continue ;; esac            # 範圍埠不檢查
      [ "$(own_port "$svc" "$target")" = "$pub" ] && continue
      if port_busy "$pub"; then
        busy=$((busy + 1))
        alt="$(find_free_port $((pub + 1)) || true)"
        var="$(grep -oE "\\\$\\{[A-Za-z_][A-Za-z0-9_]*:-$pub\\}" "$FILE" | head -1 | sed 's/^\${\([^:]*\):-.*/\1/' || true)"
        echo "錯誤:服務 $svc 要用的主機埠 $pub 已被占用(不會停掉占用它的程式或容器):" >&2
        lsof -nP -iTCP:"$pub" -sTCP:LISTEN 2>/dev/null | sed 's/^/  /' >&2 || true
        if [ -n "$var" ]; then
          echo "  改用其他埠:$var=${alt:-<可用埠>} bash compose.sh up -p $PROJ …" >&2
        else
          sv="$(printf '%s' "$svc" | tr 'a-z' 'A-Z' | sed 's/[^A-Z0-9]/_/g')_PORT"
          echo "  compose 檔把 $pub 寫死;改成 \"127.0.0.1:\${$sv:-$pub}:$target\" 後用 $sv=${alt:-<可用埠>} 換埠" >&2
        fi
      fi
    done <<EOF
$PORTS
EOF
    [ "$busy" -eq 0 ] || exit 4

    if [ "$BUILD" = 1 ]; then up_args=(up -d --build); else up_args=(up -d); fi
    if ! dc "${up_args[@]}"; then
      echo "錯誤:docker compose up 失敗" >&2
      dump_failure; exit 1
    fi

    POLL="${COMPOSE_SH_POLL:-2}"
    DEADLINE=$(( $(date +%s) + TIMEOUT ))
    while :; do
      ST="$(dc ps -a --format '{{.Service}}|{{.State}}|{{.Health}}|{{.ExitCode}}' 2>/dev/null || true)"
      waiting=""; failed=""; n=0
      while IFS='|' read -r svc state health code; do   # 用 | 分隔:空的 Health 欄不會被合併
        [ -n "$svc" ] || continue
        n=$((n + 1))
        case "$state:$health" in
          running:healthy|running:) ;;
          *:unhealthy) failed="$failed $svc(unhealthy)" ;;
          exited:*|dead:*) [ "${code:-1}" = 0 ] || failed="$failed $svc($state,exit=$code)" ;;
          restarting:*) failed="$failed $svc(restarting,exit=$code)" ;;   # crash loop:不等到逾時
          *) waiting="$waiting $svc($state${health:+/$health})" ;;
        esac
      done <<EOF
$ST
EOF
      if [ -n "$failed" ]; then
        echo "錯誤:服務失敗:$failed" >&2; dump_failure; exit 1
      fi
      [ "$n" -gt 0 ] && [ -z "$waiting" ] && break
      if [ "$(date +%s)" -ge "$DEADLINE" ]; then
        echo "錯誤:${TIMEOUT} 秒內沒有全部就緒,還在等:${waiting:- (沒有任何容器)}" >&2
        dump_failure; exit 1
      fi
      sleep "$POLL"
    done

    while read -r svc target pub hip; do
      [ -n "$svc" ] || continue
      p="$(own_port "$svc" "$target")"
      [ -n "$p" ] && echo "url=http://localhost:$p port=$p service=$svc"
    done <<EOF
$PORTS
EOF
    echo "up project=$PROJ services=$n"
    ;;

  down)
    args=(down)
    [ "$VOLUMES" = 1 ] && args+=(--volumes)
    [ "$IMAGES" = 1 ] && args+=(--rmi local)
    dc "${args[@]}"
    if [ "$VOLUMES" = 1 ]; then v=removed; else v=kept; fi
    echo "down project=$PROJ volumes=$v"
    ;;

  ps) dc ps -a ;;

  logs) dc logs --no-color --tail "$TAIL" "${SERVICES[0]}" ;;
esac
