#!/bin/bash
# Lock observation for a DDL (always rolled back).
#
#   locks.sh <name> --dsn DSN (--sql 'DDL' | --file F | --goose-up MIGRATION.sql) [--lock-timeout 2s]
#            [--hold-dsn DSN --hold 'SQL' [--hold-seconds 8]] [--probe-dsn DSN --probe 'SQL'] [--monitor-dsn DSN]
#
# Default mode: BEGIN; <DDL>; list the relation locks this transaction holds; ROLLBACK. Each lock is printed with
#   what it blocks (reads+writes / writes / ddl-only), from PostgreSQL's lock conflict table.
# --hold: session "hold" runs BEGIN; <hold SQL>; pg_sleep(hold-seconds) (e.g. an open transaction touching a hot
#   table); then "ddl" runs the DDL with lock_timeout; then (optional) "probe" runs e.g. an UPDATE on the hot table.
#   A monitor snapshot of pg_stat_activity / pg_locks shows who waits on whom (blocked_by uses session names).
#   Every session has statement_timeout and lock_timeout, so nothing waits forever; the hold session is cancelled at the end.
# --goose-up takes the Up section of a goose file; files marked NO TRANSACTION are refused (cannot run in a transaction).
# Last line: JSON summary. Exit: 0 observed, 1 error, 2 usage, 4 DSN not this container.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
DSN=""; SQL=""; LT="2s"; HOLD_DSN=""; HOLD=""; HOLD_S=8; PROBE_DSN=""; PROBE=""; MON=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dsn) DSN="${2:?}"; shift 2 ;;
    --sql) SQL="${2:?}"; shift 2 ;;
    --file) [ -f "${2:?}" ] || die "檔案不存在:$2" 2; SQL="$(cat "$2")"; shift 2 ;;
    --goose-up)
      [ -f "${2:?}" ] || die "檔案不存在:$2" 2
      grep -qiE '^-- \+goose NO TRANSACTION' "$2" && die "$2 是 NO TRANSACTION 檔,不能在交易內觀察;改用 --hold 模式搭配手動語句,或推導" 1
      SQL="$(awk 'tolower($0) ~ /^-- \+goose up/{f=1; next} tolower($0) ~ /^-- \+goose down/{f=0} f && $0 !~ /^-- \+goose /' "$2")"
      shift 2 ;;
    --lock-timeout) LT="${2:?}"; shift 2 ;;
    --hold-dsn) HOLD_DSN="${2:?}"; shift 2 ;;
    --hold) HOLD="${2:?}"; shift 2 ;;
    --hold-seconds) HOLD_S="${2:?}"; shift 2 ;;
    --probe-dsn) PROBE_DSN="${2:?}"; shift 2 ;;
    --probe) PROBE="${2:?}"; shift 2 ;;
    --monitor-dsn) MON="${2:?}"; shift 2 ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -n "$DSN" ] && [ -n "$SQL" ] || die "需要 --dsn 與 --sql / --file / --goose-up" 2
case "$HOLD_S" in *[!0-9]*|"") die "--hold-seconds 要是整數秒" 2 ;; esac
[ -z "$HOLD" ] || [ -n "$HOLD_DSN" ] || HOLD_DSN="$DSN"
[ -z "$PROBE" ] || [ -n "$PROBE_DSN" ] || PROBE_DSN="$DSN"
[ -n "$MON" ] || MON="$DSN"
load_state "$NAME"; verify_container "$NAME"
guard_dsns "$DSN" ${HOLD_DSN:+"$HOLD_DSN"} ${PROBE_DSN:+"$PROBE_DSN"} "$MON"
if [ -n "$HOLD" ]; then
  # Seeing other roles' wait_event and cancelling their backends needs superuser (or pg_read_all_stats + pg_signal_backend).
  priv="$(printf "SELECT rolsuper OR (pg_has_role(current_user, 'pg_read_all_stats', 'member') AND pg_has_role(current_user, 'pg_signal_backend', 'member')) FROM pg_roles WHERE rolname = current_user;\n" | psql_dsn "$MON" -qAt 2>&1 || true)"
  [ "$priv" = t ] || die "--hold 模式的 --monitor-dsn 要是 superuser(或 pg_read_all_stats + pg_signal_backend)才能看到 / 取消其他角色的 session;請給 superuser DSN" 2
fi

WORK="$(mktemp -d "$(name_dir "$NAME")/locks.XXXXXX" 2>/dev/null || { mkdir -p "$(name_dir "$NAME")"; mktemp -d "$(name_dir "$NAME")/locks.XXXXXX"; })"
PIDS=""
cleanup() {
  # Cancel our backends first so the background psql sessions end on their own, then reap / kill leftovers.
  [ -n "$HOLD" ] && printf "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'dbrev-lock-%%' AND pid <> pg_backend_pid();\n" \
    | psql_dsn "$MON" -qAt >/dev/null 2>&1 || true
  local p
  for p in $PIDS; do
    local k=0; while kill -0 "$p" 2>/dev/null && [ $k -lt 20 ]; do sleep 0.25; k=$((k + 1)); done
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

blocks_of() { # lock mode -> what ordinary statements it blocks
  case "$1" in
    AccessShareLock) echo "ddl-only(ACCESS EXCLUSIVE)" ;;
    RowShareLock) echo "EXCLUSIVE/ACCESS EXCLUSIVE(ddl, REFRESH MV)" ;;
    RowExclusiveLock) echo "SHARE+(CREATE INDEX non-concurrent, ddl)" ;;
    ShareUpdateExclusiveLock) echo "ddl/VACUUM/ANALYZE/CREATE INDEX CONCURRENTLY; reads+writes ok" ;;
    ShareLock) echo "writes(INSERT/UPDATE/DELETE)" ;;
    ShareRowExclusiveLock) echo "writes(INSERT/UPDATE/DELETE)" ;;
    ExclusiveLock) echo "writes + SELECT FOR UPDATE/SHARE; plain reads ok" ;;
    AccessExclusiveLock) echo "reads+writes(everything)" ;;
    *) echo "?" ;;
  esac
}
LOCKQ="SELECT coalesce((SELECT rn.nspname || '.' || rc.relname FROM pg_class rc JOIN pg_namespace rn ON rn.oid = rc.relnamespace WHERE rc.oid = l.relation), 'oid:' || l.relation::oid::text), l.mode FROM pg_locks l WHERE l.pid = pg_backend_pid() AND l.granted AND l.locktype = 'relation' AND l.relation <> 'pg_locks'::regclass AND NOT EXISTS (SELECT 1 FROM pg_class cc WHERE cc.oid = l.relation AND cc.relnamespace = 'pg_catalog'::regnamespace) ORDER BY 1, 2;"

if [ -z "$HOLD" ]; then
  out="$(printf "SET application_name = 'dbrev-lock-ddl';\nSET lock_timeout = '%s';\nBEGIN;\n%s\n;\n\\\\echo __DBREV_LOCKS__\n%s\nROLLBACK;\n" "$LT" "$SQL" "$LOCKQ" \
        | PSQL_MERGE_STDERR=1 psql_dsn "$DSN" -qAt -F '|' 2>&1)" && rc=0 || rc=$?
  if [ $rc -ne 0 ]; then
    echo "$out" | tail -5 >&2
    python3 -I -c 'import json,sys; print(json.dumps({"mode":"in-transaction","ok":False,"error":sys.argv[1]},ensure_ascii=False))' \
      "$(echo "$out" | grep -m1 -oE '[0-9A-Z]{5}: .{0,120}' || true)"
    exit 1
  fi
  echo "| object | mode | blocks |"; echo "|---|---|---|"
  n=0; ae=0
  while IFS='|' read -r obj mode; do
    case "$mode" in *Lock) ;; *) continue ;; esac   # skip NOTICE / other non-lock lines
    [ -n "$obj" ] || continue
    echo "| $obj | $mode | $(blocks_of "$mode") |"; n=$((n + 1))
    [ "$mode" = AccessExclusiveLock ] && ae=$((ae + 1))
  done < <(echo "$out" | sed -n '/^__DBREV_LOCKS__$/,$p' | sed 1d)
  printf '{"mode":"in-transaction","locks":%d,"access_exclusive":%d,"rolled_back":true,"ok":true}\n' "$n" "$ae"
  exit 0
fi

# ---- hold mode ----
ST_HOLD="$((HOLD_S + 20))s"
(printf "SET application_name = 'dbrev-lock-hold';\nBEGIN;\n%s\n;\nSELECT pg_sleep(%s);\nROLLBACK;\n" "$HOLD" "$HOLD_S" \
  | ST_OVERRIDE="$ST_HOLD" psql_dsn "$HOLD_DSN" -qAt > "$WORK/hold.out" 2>&1) & PIDS="$PIDS $!"
i=0
until [ "$(printf "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'dbrev-lock-hold' AND wait_event = 'PgSleep';\n" | psql_dsn "$MON" -qAt 2>/dev/null)" = "1" ]; do
  i=$((i + 1)); [ $i -lt 40 ] || { cat "$WORK/hold.out" >&2; die "hold session 沒有進入等待(hold SQL 失敗?)" 1; }
  sleep 0.25
done
(printf "SET application_name = 'dbrev-lock-ddl';\nSET lock_timeout = '%s';\nBEGIN;\n%s\n;\nROLLBACK;\n" "$LT" "$SQL" \
  | { set +e; psql_dsn "$DSN" -qAt > "$WORK/ddl.out" 2>&1; echo "rc=$?" >> "$WORK/ddl.out"; }) & DDL_PID=$!; PIDS="$PIDS $DDL_PID"
wait_lock() { # <session> : until it waits on a lock (max 5 s)
  local i=0
  until [ "$(printf "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'dbrev-lock-%s' AND wait_event_type = 'Lock';\n" "$1" | psql_dsn "$MON" -qAt 2>/dev/null)" = 1 ]; do
    i=$((i + 1)); [ $i -lt 50 ] || return 0; sleep 0.1
  done
}
wait_lock ddl
PROBE_PID=""
if [ -n "$PROBE" ]; then
  (printf "SET application_name = 'dbrev-lock-probe';\nSET lock_timeout = '%s';\nBEGIN;\n%s\n;\nROLLBACK;\n" "$LT" "$PROBE" \
    | { set +e; psql_dsn "$PROBE_DSN" -qAt > "$WORK/probe.out" 2>&1; echo "rc=$?" >> "$WORK/probe.out"; }) & PROBE_PID=$!; PIDS="$PIDS $PROBE_PID"
  wait_lock probe
fi
SNAP="$(printf "%s\n" \
  "WITH s AS (SELECT pid, application_name AS sess, state, wait_event_type, wait_event FROM pg_stat_activity WHERE application_name LIKE 'dbrev-lock-%')" \
  "SELECT s.sess, s.pid, s.state, coalesce(s.wait_event_type,'') || ':' || coalesce(s.wait_event,''), coalesce((SELECT string_agg(b.sess, ',') FROM s b WHERE b.pid = ANY (pg_blocking_pids(s.pid))), '') FROM s ORDER BY 1;" \
  "\\echo __DBREV_LOCKS__" \
  "SELECT a.application_name, coalesce((SELECT rn.nspname || '.' || rc.relname FROM pg_class rc JOIN pg_namespace rn ON rn.oid = rc.relnamespace WHERE rc.oid = l.relation), 'oid:' || l.relation::oid::text), l.mode, l.granted FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE a.application_name LIKE 'dbrev-lock-%' AND l.locktype = 'relation' ORDER BY 1, 2, 3;" \
  | psql_dsn "$MON" -qAt -F '|' 2>&1 || true)"
echo "### sessions(snapshot)"; echo "| session | pid | state | wait | blocked_by |"; echo "|---|---|---|---|---|"
echo "$SNAP" | sed '/^__DBREV_LOCKS__$/,$d' | while IFS='|' read -r s p st w b; do [ -n "$s" ] && echo "| ${s#dbrev-lock-} | $p | $st | $w | $(echo "$b" | sed 's/dbrev-lock-//g') |"; done
echo "### relation locks(snapshot)"; echo "| session | object | mode | granted |"; echo "|---|---|---|---|"
echo "$SNAP" | sed -n '/^__DBREV_LOCKS__$/,$p' | sed 1d | while IFS='|' read -r s o m g; do [ -n "$s" ] && echo "| ${s#dbrev-lock-} | $o | $m | $g |"; done
wait "$DDL_PID" 2>/dev/null || true
[ -z "$PROBE_PID" ] || wait "$PROBE_PID" 2>/dev/null || true
outcome() { # file -> ok | timeout(55P03) | error(code)
  local f="$1" c
  c="$(grep -oE 'ERROR: +[0-9A-Z]{5}' "$f" | head -1 | grep -oE '[0-9A-Z]{5}$' || true)"
  if [ -z "$c" ] && grep -q '^rc=0$' "$f"; then echo ok
  elif [ "$c" = 55P03 ]; then echo "timeout(55P03)"
  elif [ -z "$c" ] && grep -q '^psql: error:' "$f"; then echo "connect-failed"
  else echo "error(${c:-?})"; fi
}
DDL_RES="$(outcome "$WORK/ddl.out")"; PROBE_RES=""; [ -z "$PROBE" ] || PROBE_RES="$(outcome "$WORK/probe.out")"
echo "### outcomes"; echo "ddl: $DDL_RES $(grep -m1 ERROR "$WORK/ddl.out" || true)"
[ -z "$PROBE" ] || echo "probe: $PROBE_RES $(grep -m1 ERROR "$WORK/probe.out" || true)"
by() { echo "$SNAP" | sed '/^__DBREV_LOCKS__$/,$d' | awk -F'|' -v s="dbrev-lock-$1" '$1==s{gsub(/dbrev-lock-/,"",$5); print $5}'; }
printf '{"mode":"hold","ddl":"%s","ddl_blocked_by":"%s","probe":"%s","probe_blocked_by":"%s","ok":true}\n' \
  "$DDL_RES" "$(by ddl)" "$PROBE_RES" "$(by probe)"
