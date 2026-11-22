#!/bin/bash
# Seed data in the throwaway container. Prefer the project's own seed script; generate_series is the fallback.
#
#   seed.sh <name> --dsn DSN --file SEED.sql [--var k=v]...            project seed script (piped to psql -v k=v)
#   seed.sh <name> --dsn DSN --table T --rows N --col 'col=expr' [--col …] [--batch 100000]
#            expressions may use g (1..N), e.g. --col "name='user-'||g" --col "balance=g % 1000"
#
# Batches commit separately (statement_timeout 300s each) so one Bash call stays well under 600 s; ANALYZE at the end.
# Prints free space on the container's tmpfs before and after. Exit: 1 failure, 2 usage, 4 DSN not this container.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
DSN=""; FILE=""; VARS=(); TABLE=""; ROWS=""; COLS=(); BATCH=100000
while [ $# -gt 0 ]; do
  case "$1" in
    --dsn) DSN="${2:?}"; shift 2 ;;
    --file) FILE="${2:?}"; shift 2 ;;
    --var) VARS+=(-v "${2:?}"); shift 2 ;;
    --table) TABLE="${2:?}"; shift 2 ;;
    --rows) ROWS="${2:?}"; shift 2 ;;
    --col) COLS+=("${2:?}"); shift 2 ;;
    --batch) BATCH="${2:?}"; shift 2 ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -n "$DSN" ] || die "--dsn 必填" 2
load_state "$NAME"; verify_container "$NAME"
guard_dsns "$DSN"
free_mb() { docker exec "$CONTAINER" sh -c 'df -Pk "${PGDATA:-/var/lib/postgresql}"' | awk 'NR==2{print int($4/1024)}'; }
echo "tmpfs_free_mb_before=$(free_mb)"
START=$(date +%s)
export ST_OVERRIDE=300s

if [ -n "$FILE" ]; then
  [ -f "$FILE" ] || die "--file 不存在:$FILE" 2
  bad="$(python3 -I "$KIT_DIR/scripts/_txcheck.py" --connect < "$FILE")" || die "種子腳本有 \\c / \\connect / \\!($bad),拒絕" 4
  psql_dsn "$DSN" -q ${VARS[@]+"${VARS[@]}"} < "$FILE"
  echo "seed file=$FILE seconds=$(( $(date +%s) - START )) tmpfs_free_mb_after=$(free_mb)"
  exit 0
fi

[ -n "$TABLE" ] && [ -n "$ROWS" ] && [ ${#COLS[@]} -gt 0 ] || die "需要 --file,或 --table、--rows、--col" 2
for x in "$ROWS" "$BATCH"; do case "$x" in ""|*[!0-9]*) die "--rows / --batch 要是 ≥ 1 的整數" 2 ;; esac; done
ROWS=$((10#$ROWS)); BATCH=$((10#$BATCH))
[ "$ROWS" -ge 1 ] && [ "$BATCH" -ge 1 ] || die "--rows / --batch 要是 ≥ 1 的整數" 2
case "$TABLE" in *[!A-Za-z0-9_.\"]*) die "--table 只能是 schema.table" 2 ;; esac
names=""; exprs=""
for c in "${COLS[@]}"; do
  n="${c%%=*}"; e="${c#*=}"
  [ "$n" != "$c" ] && [ -n "$n" ] || die "--col 格式是 col=expr:$c" 2
  case "$n" in *[!A-Za-z0-9_]*) die "欄位名稱只能是英數與底線:$n" 2 ;; esac
  names="${names:+$names, }$n"; exprs="${exprs:+$exprs, }$e"
done
probe_sql="$(printf 'INSERT INTO %s (%s) SELECT %s FROM generate_series(1, 1) AS g' "$TABLE" "$names" "$exprs")"
bad="$(printf '%s\n' "$probe_sql" | python3 -I "$KIT_DIR/scripts/_txcheck.py")" || die "--col 運算式有交易控制或 psql 指令($bad),拒絕" 2
case "$exprs" in *";"*) die "--col 運算式不能含分號" 2 ;; esac
from=1; b=0
while [ "$from" -le "$ROWS" ]; do
  to=$((from + BATCH - 1)); [ "$to" -le "$ROWS" ] || to="$ROWS"
  printf 'INSERT INTO %s (%s) SELECT %s FROM generate_series(%d, %d) AS g;\n' "$TABLE" "$names" "$exprs" "$from" "$to" \
    | psql_dsn "$DSN" -q || die "第 $((b + 1)) 批($from–$to)失敗" 1
  b=$((b + 1)); from=$((to + 1))
done
printf 'ANALYZE %s;\n' "$TABLE" | psql_dsn "$DSN" -q
echo "seed table=$TABLE rows=$ROWS batches=$b seconds=$(( $(date +%s) - START )) tmpfs_free_mb_after=$(free_mb)"
