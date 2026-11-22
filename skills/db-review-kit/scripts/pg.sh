#!/bin/bash
# Throwaway PostgreSQL container for db-reviewer. Data lives on tmpfs; nothing persists.
#
#   pg.sh check                                   local docker? memory / cpu / tmp disk, go version
#   pg.sh up <name> --image IMG [--mount SRC:DEST]... [--env K=V]... [--env-random NAME...]
#            [--role ROLE=PWVAR]... [--db NAME]... [--superuser postgres] [--tmpfs-size 1g] [--timeout 120]
#   pg.sh dsn <name> <role> <db> [--options '-c k=v']   print a DSN for a role printed by up
#   pg.sh psql <name> <dsn> [psql args...]        psql inside the container (SQL from stdin unless -c)
#   pg.sh guard <name> <dsn>...                   every DSN must be 127.0.0.1:<this container's port>
#   pg.sh rm <name> [--purge]                     remove the container (--purge also deletes the tmp dir)
#   pg.sh gc <name>                               remove leftovers labelled dbrev=<name> and named dbrev-<name>-*
#
# Exit codes: 1 failure, 2 usage, 3 docker not running, 4 refused (non-local docker / DSN guard / foreign container).
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
CMD="$1"; shift

list_ours() { # names of containers with label dbrev=<name> AND prefix dbrev-<name>-
  docker ps -a --filter "label=dbrev=$1" --format '{{.Names}}' | while IFS= read -r n; do
    case "$n" in "dbrev-$1-"*) echo "$n" ;; esac
  done
}

case "$CMD" in
  check)
    require_local_docker
    echo "docker=local context=$(docker context show 2>/dev/null || echo "DOCKER_HOST") host=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || echo "${DOCKER_HOST:-?}")"
    docker info --format 'docker_mem_mb={{.MemTotal}} docker_cpus={{.NCPU}} server={{.ServerVersion}}' \
      | awk '{ split($1,a,"="); printf "docker_mem_mb=%d %s %s\n", a[2]/1048576, $2, $3 }'
    own_dir "$KIT_TMP"
    echo "tmp=$KIT_TMP tmp_free_mb=$(df -Pk "$KIT_TMP" | awk 'NR==2{print int($4/1024)}')"
    if command -v go >/dev/null 2>&1; then echo "go=$(go env GOVERSION)"; else echo "go=missing"; fi
    ;;

  up)
    NAME="${1:-}"; check_name "$NAME"; shift
    IMAGE=""; SUPERUSER="postgres"; TMPFS_SIZE="1g"; TIMEOUT=120
    MOUNTS=(); ENVS=(); RANDOMS=(); ROLESPEC=(); DBLIST=()
    while [ $# -gt 0 ]; do
      case "$1" in
        --image) IMAGE="${2:?--image 需要值}"; shift 2 ;;
        --mount) MOUNTS+=("${2:?--mount 需要 SRC:DEST}"); shift 2 ;;
        --env) ENVS+=("${2:?--env 需要 K=V}"); shift 2 ;;
        --env-random) shift; while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do RANDOMS+=("$1"); shift; done ;;
        --role) ROLESPEC+=("${2:?--role 需要 ROLE=PWVAR}"); shift 2 ;;
        --db) DBLIST+=("${2:?--db 需要名稱}"); shift 2 ;;
        --superuser) SUPERUSER="${2:?}"; shift 2 ;;
        --tmpfs-size) TMPFS_SIZE="${2:?}"; shift 2 ;;
        --timeout) TIMEOUT="${2:?}"; shift 2 ;;
        *) die "未知參數:$1" 2 ;;
      esac
    done
    case "$IMAGE" in *[!A-Za-z0-9._/:@-]*) die "--image 只能含 A-Z a-z 0-9 . _ / : @ -" 2 ;; esac
    case "$SUPERUSER" in ""|*[!A-Za-z0-9_-]*) die "--superuser 只能是英數、底線、連字號" 2 ;; esac
    [ -n "$IMAGE" ] || die "--image 必填(依專案設定,例如 compose 的 db 映像)" 2
    case "$IMAGE" in *postgres*|*postgis*|*pgvector*|*timescale*) ;; *) die "映像看起來不是 PostgreSQL:$IMAGE" 2 ;; esac
    printf '%s' "$TMPFS_SIZE" | grep -Eq '^[0-9]+[kmgKMG]?$' || die "--tmpfs-size 格式例:512m、2g" 2
    printf '%s' "$TIMEOUT" | grep -Eq '^[0-9]+$' && [ "$TIMEOUT" -ge 1 ] || die "--timeout 要是秒數" 2
    require_local_docker
    [ -z "$(list_ours "$NAME")" ] || die "已有 dbrev-$NAME-* 容器;先 pg.sh gc $NAME" 1

    ensure_name_dir "$NAME"; DIR="$(name_dir "$NAME")"
    SUPERPASS="$(rand_hex 16)"
    PULLED=""
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then docker pull -q "$IMAGE" >/dev/null || die "拉不到映像 $IMAGE" 1; PULLED=1; fi
    # tmpfs on every VOLUME the image declares (18+: /var/lib/postgresql; ≤17: /var/lib/postgresql/data), so no
    # anonymous on-disk volume is created and --tmpfs-size really caps the data.
    VOLS="$(docker image inspect -f '{{range $k, $v := .Config.Volumes}}{{$k}} {{end}}' "$IMAGE")"
    [ -n "$VOLS" ] || VOLS="/var/lib/postgresql"
    TMPFS_ARGS=(); for v in $VOLS; do TMPFS_ARGS+=(--tmpfs "$v:rw,size=$TMPFS_SIZE"); done
    RUNARGS=(-d --label "dbrev=$NAME" "${TMPFS_ARGS[@]}" --shm-size 256m -p "127.0.0.1::5432"
             -e "POSTGRES_USER=$SUPERUSER" -e "POSTGRES_PASSWORD=$SUPERPASS")
    for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do
      src="${m%%:*}"; rest="${m#*:}"; dest="${rest%%:*}"; mode=""
      [ "$rest" != "$dest" ] && mode="${rest#*:}"
      [ -n "$src" ] && [ -n "$dest" ] && [ "$src" != "$m" ] || die "--mount 格式是 SRC:DEST:$m" 2
      case "$mode" in ""|ro) ;; *) die "--mount 一律唯讀,不接受模式 $mode:$m" 4 ;; esac
      case "$dest" in /*) ;; *) die "--mount 的 DEST 要是容器內絕對路徑:$dest" 2 ;; esac
      [ -e "$src" ] || die "--mount 來源不存在:$src" 1
      abs="$(cd "$(dirname "$src")" && pwd)/$(basename "$src")"
      RUNARGS+=(--mount "type=bind,source=$abs,target=$dest,readonly")
    done
    STATE_RANDOM=""
    for v in ${RANDOMS[@]+"${RANDOMS[@]}"}; do
      case "$v" in ""|*[!A-Za-z0-9_]*) die "--env-random 名稱不合法:$v" 2 ;; PGDATA|POSTGRES_USER) die "$v 不能用 --env-random 設定" 2 ;; esac
      [ "$v" = "POSTGRES_PASSWORD" ] && continue   # always random already
      val="$(rand_hex 16)"; RUNARGS+=(-e "$v=$val"); STATE_RANDOM="$STATE_RANDOM $v=$val"
    done
    for kv in ${ENVS[@]+"${ENVS[@]}"}; do
      case "$kv" in [A-Za-z_]*=*) ;; *) die "--env 需要 K=V:$kv" 2 ;; esac
      case "${kv%%=*}" in POSTGRES_PASSWORD|POSTGRES_USER) die "${kv%%=*} 由 pg.sh 設定" 2 ;; esac
      [ "${kv%%=*}" != PGDATA ] || die "PGDATA 不能用 --env 改(資料必須在映像宣告的 VOLUME,也就是 tmpfs 上)" 2
      RUNARGS+=(-e "$kv")
    done
    CONTAINER="dbrev-$NAME-$(rand_hex 3)"
    START=$(date +%s)
    cleanup_fail() { docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true; rm -f "$(state_file "$NAME")"; }
    UP_OK=""
    trap '[ -n "$UP_OK" ] || cleanup_fail' EXIT
    trap 'exit 130' INT TERM
    docker run --name "$CONTAINER" "${RUNARGS[@]}" "$IMAGE" >/dev/null || { cleanup_fail; die "docker run 失敗" 1; }
    # init (docker-entrypoint-initdb.d) runs on a socket-only temp server; TCP on 127.0.0.1 answers only after the final start.
    i=0
    until docker exec "$CONTAINER" pg_isready -q -h 127.0.0.1 -p 5432 -U "$SUPERUSER" >/dev/null 2>&1; do
      if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" != "true" ]; then
        echo "---- 容器提早結束(init 失敗?),最後 40 行 log:" >&2; docker logs --tail 40 "$CONTAINER" >&2 2>&1 || true
        cleanup_fail; die "PostgreSQL 初始化失敗" 1
      fi
      i=$((i + 1))
      if [ $i -ge $((TIMEOUT * 2)) ]; then
        docker logs --tail 40 "$CONTAINER" >&2 2>&1 || true; cleanup_fail; die "PostgreSQL ${TIMEOUT} 秒內沒有就緒" 1
      fi
      sleep 0.5
    done
    PORT="$(docker port "$CONTAINER" 5432/tcp | grep -m1 '^127\.0\.0\.1:' | sed 's/.*://' || true)"
    [ -n "$PORT" ] || { cleanup_fail; die "取不到 127.0.0.1 對應埠" 1; }

    ROLES="$SUPERUSER=$SUPERPASS"
    for rs in ${ROLESPEC[@]+"${ROLESPEC[@]}"}; do
      r="${rs%%=*}"; pv="${rs#*=}"
      [ "$r" != "$rs" ] && [ -n "$r" ] && [ -n "$pv" ] || die "--role 格式是 ROLE=PWVAR:$rs" 2
      pw=""
      [ "$pv" != POSTGRES_PASSWORD ] || pw="$SUPERPASS"
      for x in $STATE_RANDOM; do [ "${x%%=*}" = "$pv" ] && pw="${x#*=}"; done
      for kv in ${ENVS[@]+"${ENVS[@]}"}; do [ "${kv%%=*}" = "$pv" ] && pw="${kv#*=}"; done
      [ -n "$pw" ] || { cleanup_fail; die "--role $rs:$pv 不在 --env-random / --env 裡" 2; }
      case "$r$pw" in *[!A-Za-z0-9_-]*) cleanup_fail; die "--role $rs:角色名稱與密碼只能是英數、底線、連字號(秘密請用 --env-random)" 2 ;; esac
      ROLES="$ROLES $r=$pw"
    done
    DBS="postgres"
    for db in ${DBLIST[@]+"${DBLIST[@]}"}; do
      case "$db" in ""|*[!A-Za-z0-9_]*) cleanup_fail; die "--db 名稱只能是英數與底線:$db" 2 ;; esac
      exists="$(docker exec "$CONTAINER" psql -X -At -U "$SUPERUSER" -d postgres -c "SELECT 1 FROM pg_database WHERE datname='$db'")"
      if [ "$exists" != "1" ]; then
        docker exec "$CONTAINER" psql -X -q -v ON_ERROR_STOP=1 -U "$SUPERUSER" -d postgres -c "CREATE DATABASE \"$db\"" >/dev/null \
          || { cleanup_fail; die "建立資料庫 $db 失敗" 1; }
        echo "created db=$db"
      fi
      DBS="$DBS $db"
    done
    umask 077
    {
      echo "CONTAINER='$CONTAINER'"; echo "PORT='$PORT'"; echo "IMAGE='$IMAGE'"
      echo "SUPERUSER='$SUPERUSER'"; echo "SUPERPASS='$SUPERPASS'"
      echo "ROLES='$ROLES'"; echo "DBS='$DBS'"; echo "RANDOM_ENV='${STATE_RANDOM# }'"; echo "PULLED='$PULLED'"
    } > "$(state_file "$NAME")"
    UP_OK=1
    echo "container=$CONTAINER port=$PORT image=$IMAGE tmpfs=$TMPFS_SIZE tmpfs_paths=$(echo $VOLS | tr ' ' ',') ready_seconds=$(( $(date +%s) - START ))"
    for rp in $ROLES; do
      for db in $DBS; do
        echo "dsn role=${rp%%=*} db=$db url=$(dsnpy build "${rp%%=*}" "${rp#*=}" "$PORT" "$db")"
      done
    done
    ;;

  dsn)
    NAME="${1:-}"; check_name "$NAME"; ROLE="${2:?用法:pg.sh dsn <name> <role> <db> [--options '…']}"; DB="${3:?缺少 <db>}"
    OPTS=""; [ "${4:-}" = "--options" ] && OPTS="${5:?--options 需要值}"
    load_state "$NAME"
    pw=""; for rp in $ROLES; do [ "${rp%%=*}" = "$ROLE" ] && pw="${rp#*=}"; done
    [ -n "$pw" ] || die "角色 $ROLE 沒有用 --role 登記(已登記:$(for rp in $ROLES; do printf '%s ' "${rp%%=*}"; done))" 1
    dsnpy build "$ROLE" "$pw" "$PORT" "$DB" "$OPTS"
    ;;

  psql)
    NAME="${1:-}"; check_name "$NAME"; DSN="${2:?用法:pg.sh psql <name> <dsn> [psql args]}"; shift 2
    load_state "$NAME"; verify_container "$NAME"
    # Only output / variable flags: connection options (-d -h -p -U, a second DSN) could leave the container.
    ARGS=(); CMDS=""
    while [ $# -gt 0 ]; do
      case "$1" in
        -[qAtX]|-[qAtX][qAtX]|-[qAtX][qAtX][qAtX]|-[qAtX][qAtX][qAtX][qAtX]) ARGS+=("$1"); shift ;;
        -F|-v|-P) [ $# -ge 2 ] || die "$1 需要值" 2; ARGS+=("$1" "$2"); shift 2 ;;
        -c) [ $# -ge 2 ] || die "-c 需要 SQL" 2; CMDS="$CMDS$2
"; ARGS+=("$1" "$2"); shift 2 ;;
        *) die "pg.sh psql 只接受 -q -A -t -X -F -v -P -c(不接受連線參數):$1" 2 ;;
      esac
    done
    D="$(name_dir "$NAME")"; IN="$(mktemp "$D/psql-in.XXXXXX")"; trap 'rm -f "$IN"' EXIT
    if [ -n "$CMDS" ]; then : > "$IN"; else cat > "$IN"; fi
    bad="$(printf '%s' "$CMDS" | cat - "$IN" | python3 -I "$KIT_DIR/scripts/_txcheck.py" --connect)" \
      || die "SQL 裡有 \\c / \\connect / \\!($bad),會離開本容器的連線,拒絕" 4
    psql_dsn "$DSN" ${ARGS[@]+"${ARGS[@]}"} < "$IN"
    ;;

  guard)
    NAME="${1:-}"; check_name "$NAME"; shift
    [ $# -ge 1 ] || die "用法:pg.sh guard <name> <dsn>..." 2
    load_state "$NAME"; verify_container "$NAME"
    out="$(dsnpy guard "$PORT" "$@")" && rc=0 || rc=$?
    echo "$out"
    [ $rc -eq 0 ] || exit 4
    ;;

  rm)
    NAME="${1:-}"; check_name "$NAME"; PURGE=""; [ "${2:-}" = "--purge" ] && PURGE=1
    require_local_docker
    PULLED=""; IMAGE=""
    sf="$(state_file "$NAME")"; if [ -f "$sf" ] && [ -O "$sf" ]; then PULLED="$(sed -n "s/^PULLED='\(.*\)'$/\1/p" "$sf")"; IMAGE="$(sed -n "s/^IMAGE='\(.*\)'$/\1/p" "$sf")"; fi
    n=0
    for c in $(list_ours "$NAME"); do docker rm -f -v "$c" >/dev/null || die "刪除容器 $c 失敗" 1; echo "removed container=$c"; n=$((n + 1)); done
    # the image is removed too when this kit pulled it for this name and no other container uses it
    if [ -n "$PURGE" ] && [ -n "$PULLED" ] && [ -n "$IMAGE" ] && [ -z "$(docker ps -aq --filter "ancestor=$IMAGE")" ]; then
      docker image rm "$IMAGE" >/dev/null 2>&1 && echo "removed image=$IMAGE(本次拉的)"
    fi
    [ $n -gt 0 ] || echo "not-found name=$NAME"
    rm -f "$(state_file "$NAME")"
    if [ -n "$PURGE" ]; then rm -rf "$(name_dir "$NAME")"; echo "purged dir=$(name_dir "$NAME")"; fi
    ;;

  gc)
    NAME="${1:-}"; check_name "$NAME"
    require_local_docker
    n=0
    for c in $(list_ours "$NAME"); do docker rm -f -v "$c" >/dev/null || die "殘留容器 $c 刪不掉" 1; n=$((n + 1)); done
    rm -f "$(state_file "$NAME")"
    left="$(list_ours "$NAME" | wc -l | tr -d ' ')"
    echo "gc name=$NAME removed=$n remaining=$left"
    [ "$left" = "0" ] || exit 1
    ;;

  *) usage ;;
esac
