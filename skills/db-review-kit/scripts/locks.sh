#!/bin/bash
# Lock observation for a DDL (always rolled back).
#
#   locks.sh <name> --dsn DSN (--sql 'DDL' | --file F | --goose-up MIGRATION.sql) [--lock-timeout 2s]
#            [--hold-dsn DSN --hold 'SQL' [--hold-seconds 10]] [--probe-dsn DSN --probe 'SQL'] [--monitor-dsn DSN]
#
# Default mode: BEGIN; <DDL>; list the relation locks this transaction holds; ROLLBACK. Each lock is printed with
#   what it blocks (reads+writes / writes / ddl-only), from PostgreSQL's lock conflict table.
# --hold: session "hold" runs BEGIN; <hold SQL>; pg_sleep(hold-seconds) (e.g. an open transaction touching a hot
#   table); then "ddl" runs the DDL with lock_timeout; then (optional) "probe" runs e.g. an UPDATE on the hot table.
#   A monitor snapshot of pg_stat_activity / pg_locks shows who waits on whom (blocked_by uses session names).
#   --lock-timeout defaults to 5s in hold mode (minimum 3s, and --hold-seconds must be larger) so the monitor can catch
#   the waits; "observed":false / "ok":false when the DDL or probe was never seen waiting.
#   Every session has statement_timeout and lock_timeout, so nothing waits forever; the hold session is cancelled at the end.
# --goose-up takes the Up section of a goose file; files marked NO TRANSACTION are refused (cannot run in a transaction).
# Last line: JSON summary. Exit: 0 observed (hold mode: ok true), 1 error / not observed, 2 usage, 4 DSN not this container.
source "$(dirname "$0")/_common.sh"
RID=$$   # per-run session-name suffix: parallel runs on one container never see or cancel each other

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
DSN=""; SQL=""; LT=""; HOLD_DSN=""; HOLD=""; HOLD_S=10; PROBE_DSN=""; PROBE=""; MON=""
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
# The DDL runs between BEGIN and ROLLBACK; transaction control inside it would make it permanent.
# Best-effort pre-filter; the txid check below is the guarantee. DBREV_SELFTEST_SKIP_TXCHECK=1 exists only so the
# self-test can prove that check without a filter bypass.
# psql meta-commands are always refused (the txid check proves the rollback, not where psql connected).
for part in "$SQL" "$HOLD" "$PROBE"; do
  case "$part" in *\\*) die "SQL 不能含反斜線(psql 指令;字串裡請用 chr(92))" 2 ;; esac
done
[ "${DBREV_SELFTEST_SKIP_TXCHECK:-}" = 1 ] || for part in "$SQL" "$HOLD" "$PROBE"; do
  [ -n "$part" ] || continue
  bad="$(printf '%s\n' "$part" | python3 -I "$KIT_DIR/scripts/_txcheck.py")" \
    || die "SQL 裡有交易控制語句或 psql 指令($bad),locks.sh 無法保證 ROLLBACK,拒絕" 2
done
case "$HOLD_S" in *[!0-9]*|"") die "--hold-seconds 要是整數秒" 2 ;; esac
[ -z "$LT" ] || printf '%s' "$LT" | grep -Eq '^[0-9]+(ms|s|min)$' || die "--lock-timeout 要帶單位,格式例:2s、500ms" 2
if [ -n "$HOLD" ]; then
  # Monitoring polls through docker exec (~0.3–1 s each); the DDL / probe must keep waiting long enough to be observed.
  [ -n "$LT" ] || LT="5s"
  case "$LT" in [0-9]*s) LT_S="${LT%s}" ;; *) die "--hold 模式的 --lock-timeout 用整數秒寫,例如 5s" 2 ;; esac
  case "$LT_S" in *[!0-9]*) die "--lock-timeout 用整數秒寫,例如 5s" 2 ;; esac
  [ "$LT_S" -ge 3 ] || die "--hold 模式的 --lock-timeout 至少 3s(太短時監看還沒拍到就已逾時)" 2
  [ "$HOLD_S" -gt "$LT_S" ] || die "--hold-seconds 要大於 --lock-timeout" 2
else
  [ -n "$LT" ] || LT="2s"
fi
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
  [ -n "$HOLD" ] && printf "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name LIKE 'dbrev-lock-${RID}-%%' AND pid <> pg_backend_pid();\n" \
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
LOCKQ="SELECT coalesce((SELECT rn.nspname || '.' || rc.relname FROM pg_class rc JOIN pg_namespace rn ON rn.oid = rc.relnamespace WHERE rc.oid = l.relation), 'oid:' || l.relation::oid::text), l.mode, CASE WHEN l.relation <> ALL (:'dbrev_pre'::oid[]) THEN 'new' ELSE '' END FROM pg_locks l WHERE l.pid = pg_backend_pid() AND l.granted AND l.locktype = 'relation' AND l.relation <> 'pg_locks'::regclass AND NOT EXISTS (SELECT 1 FROM pg_class cc WHERE cc.oid = l.relation AND cc.relnamespace = 'pg_catalog'::regnamespace) ORDER BY 1, 2;"

# Every user SQL runs as:  BEGIN; <BEGIN txid>; SAVEPOINT; <SQL>; <END txid>; <extra>; ROLLBACK TO SAVEPOINT; <AFTER txid>; ROLLBACK
# with ON_ERROR_STOP off, so the markers are printed even when the SQL fails. "Rolled back" is proven only when AFTER
# exists and equals BEGIN (and END, if printed, too): a COMMIT inside the SQL — however it got past the pre-filter,
# and even if a later statement errors — makes AFTER differ or go missing. No SQL lexing is involved.
wrap_sql() { # <app-name suffix> <sql> <extra sql run before the rollback>
  printf "SET application_name = 'dbrev-lock-%s-%s';\nSET lock_timeout = '%s';\n\\\\set ON_ERROR_STOP 0\nBEGIN;\nSELECT '__DBREV_TX_BEGIN__' || txid_current();\nSAVEPOINT dbrev_sp;\n%s\n;\nSELECT '__DBREV_TX_END__' || txid_current();\n%s\nROLLBACK TO SAVEPOINT dbrev_sp;\nSELECT '__DBREV_TX_AFTER__' || txid_current();\nROLLBACK;\n" \
    "$RID" "$1" "$LT" "$2" "$3"
}
tx_rolled_back() { # <output text> : 0 if the transaction provably stayed open until our ROLLBACK
  local b e a
  b="$(printf '%s\n' "$1" | grep -m1 '^__DBREV_TX_BEGIN__' | sed 's/^__DBREV_TX_BEGIN__//' || true)"
  e="$(printf '%s\n' "$1" | grep '^__DBREV_TX_END__' | tail -1 | sed 's/^__DBREV_TX_END__//' || true)"
  a="$(printf '%s\n' "$1" | grep '^__DBREV_TX_AFTER__' | tail -1 | sed 's/^__DBREV_TX_AFTER__//' || true)"
  [ -n "$b" ] && [ "$a" = "$b" ] && { [ -z "$e" ] || [ "$e" = "$b" ]; }
}

if [ -z "$HOLD" ]; then
  # Relations that exist before the DDL; anything else in pg_locks afterwards was created by this transaction.
  # txid before / after the user SQL: if the SQL ended our transaction (COMMIT, however it got past the filter),
  # the ids differ and the run is reported as committed (structural check, no SQL lexing involved).
  out="$( { printf "SELECT coalesce(array_agg(oid)::text, '{}') AS dbrev_pre FROM pg_class \\\\gset\n"; wrap_sql ddl "$SQL" "$(printf '\\echo __DBREV_LOCKS__\n%s' "$LOCKQ")"; } \
        | PSQL_MERGE_STDERR=1 psql_dsn "$DSN" -qAt -F '|' 2>&1)" && rc=0 || rc=$?
  err="$(echo "$out" | grep -m1 -oE '(ERROR|FATAL): +[0-9A-Z]{5}: .{0,120}' || true)"
  if ! tx_rolled_back "$out"; then
    echo "$out" | grep -E 'ERROR|FATAL' | head -3 >&2
    echo "SQL 結束了交易(COMMIT 等)或無法證明已 ROLLBACK:暫存資料庫可能已被改,後續實測請 pg.sh rm 後重建" >&2
    python3 -I -c 'import json,sys; print(json.dumps({"mode":"in-transaction","rolled_back":False,"ok":False,"error":sys.argv[1] or "transaction ended inside the SQL"},ensure_ascii=False,separators=(",",":")))' "$err"
    exit 1
  fi
  if [ -n "$err" ] || [ $rc -ne 0 ]; then
    echo "$out" | grep -E 'ERROR|FATAL' | head -3 >&2
    python3 -I -c 'import json,sys; print(json.dumps({"mode":"in-transaction","rolled_back":True,"ok":False,"error":sys.argv[1]},ensure_ascii=False,separators=(",",":")))' "${err:-psql rc=$rc}"
    exit 1
  fi
  echo "| object | mode | blocks |"; echo "|---|---|---|"   # objects created by this DDL are marked new (invisible to others)
  n=0; ae=0
  while IFS='|' read -r obj mode isnew; do
    case "$mode" in *Lock) ;; *) continue ;; esac   # skip NOTICE / other non-lock lines
    [ -n "$obj" ] || continue
    if [ "$isnew" = new ]; then echo "| $obj (new in this transaction) | $mode | none (not visible to other sessions yet) |"; n=$((n + 1)); continue; fi
    echo "| $obj | $mode | $(blocks_of "$mode") |"; n=$((n + 1))
    if [ "$mode" = AccessExclusiveLock ]; then ae=$((ae + 1)); fi
  done < <(echo "$out" | sed -n '/^__DBREV_LOCKS__$/,$p' | sed 1d)
  printf '{"mode":"in-transaction","locks":%d,"access_exclusive":%d,"rolled_back":true,"ok":true}\n' "$n" "$ae"
  exit 0
fi

# ---- hold mode ----
ST_HOLD="$((HOLD_S + 20))s"
(wrap_sql hold "$HOLD" "SELECT pg_sleep($HOLD_S);" \
  | ST_OVERRIDE="$ST_HOLD" psql_dsn "$HOLD_DSN" -qAt > "$WORK/hold.out" 2>&1) & HOLD_PID=$!; PIDS="$PIDS $HOLD_PID"
i=0
until [ "$(printf "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'dbrev-lock-${RID}-hold' AND wait_event = 'PgSleep';\n" | psql_dsn "$MON" -qAt 2>/dev/null)" = "1" ]; do
  i=$((i + 1)); [ $i -lt 40 ] || { cat "$WORK/hold.out" >&2; die "hold session 沒有進入等待(hold SQL 失敗?)" 1; }
  sleep 0.25
done
(wrap_sql ddl "$SQL" "" \
  | { set +e; psql_dsn "$DSN" -qAt > "$WORK/ddl.out" 2>&1; echo "rc=$?" >> "$WORK/ddl.out"; }) & DDL_PID=$!; PIDS="$PIDS $DDL_PID"
wait_lock() { # <session> : until it waits on a lock; gives up after the lock timeout (wall clock), reports monitor errors
  local start r; start=$(date +%s)
  while :; do
    r="$(printf "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'dbrev-lock-${RID}-%s' AND wait_event_type = 'Lock';\n" "$1" | psql_dsn "$MON" -qAt 2>&1)" \
      || { echo "monitor 查詢失敗:$(echo "$r" | head -1)" >&2; return 1; }
    [ "$r" = 1 ] && return 0
    [ $(( $(date +%s) - start )) -lt "$LT_S" ] || return 1
    sleep 0.1
  done
}
OBSERVED=true
wait_lock ddl || OBSERVED=false
PROBE_PID=""
if [ -n "$PROBE" ]; then
  (wrap_sql probe "$PROBE" "" \
    | { set +e; psql_dsn "$PROBE_DSN" -qAt > "$WORK/probe.out" 2>&1; echo "rc=$?" >> "$WORK/probe.out"; }) & PROBE_PID=$!; PIDS="$PIDS $PROBE_PID"
  wait_lock probe || OBSERVED=false
fi
SNAP="$(printf "%s\n" \
  "WITH s AS (SELECT pid, application_name AS sess, state, wait_event_type, wait_event FROM pg_stat_activity WHERE application_name LIKE 'dbrev-lock-${RID}-%')" \
  "SELECT s.sess, s.pid, s.state, coalesce(s.wait_event_type,'') || ':' || coalesce(s.wait_event,''), coalesce((SELECT string_agg(b.sess, ',') FROM s b WHERE b.pid = ANY (pg_blocking_pids(s.pid))), '') FROM s ORDER BY 1;" \
  "\\echo __DBREV_LOCKS__" \
  "SELECT a.application_name, coalesce((SELECT rn.nspname || '.' || rc.relname FROM pg_class rc JOIN pg_namespace rn ON rn.oid = rc.relnamespace WHERE rc.oid = l.relation), 'oid:' || l.relation::oid::text), l.mode, l.granted FROM pg_locks l JOIN pg_stat_activity a USING (pid) WHERE a.application_name LIKE 'dbrev-lock-${RID}-%' AND l.locktype = 'relation' ORDER BY 1, 2, 3;" \
  | psql_dsn "$MON" -qAt -F '|' 2>&1 || true)"
echo "### sessions(snapshot)"; echo "| session | pid | state | wait | blocked_by |"; echo "|---|---|---|---|---|"
echo "$SNAP" | sed '/^__DBREV_LOCKS__$/,$d' | while IFS='|' read -r s p st w b; do if [ -n "$s" ]; then echo "| ${s#dbrev-lock-$RID-} | $p | $st | $w | $(echo "$b" | sed "s/dbrev-lock-$RID-//g") |"; fi; done
echo "### relation locks(snapshot)"; echo "| session | object | mode | granted |"; echo "|---|---|---|---|"
echo "$SNAP" | sed -n '/^__DBREV_LOCKS__$/,$p' | sed 1d | while IFS='|' read -r s o m g; do if [ -n "$s" ]; then echo "| ${s#dbrev-lock-$RID-} | $o | $m | $g |"; fi; done
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
DDL_RES="$(outcome "$WORK/ddl.out")"
# end the hold now (cancel its pg_sleep) and wait, so its ROLLBACK TO / AFTER marker is in hold.out before judging
printf "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name = 'dbrev-lock-%s-hold';\n" "$RID" | psql_dsn "$MON" -qAt >/dev/null 2>&1 || true
k=0; while kill -0 "$HOLD_PID" 2>/dev/null && [ $k -lt 40 ]; do sleep 0.25; k=$((k + 1)); done
if ! tx_rolled_back "$(cat "$WORK/ddl.out")"; then DDL_RES="committed(not provably rolled back)"; fi
HOLD_TX=ok; tx_rolled_back "$(cat "$WORK/hold.out")" || HOLD_TX="committed(hold SQL not provably rolled back)"
PROBE_TX=ok; [ -z "$PROBE" ] || tx_rolled_back "$(cat "$WORK/probe.out")" || PROBE_TX="committed(probe SQL not provably rolled back)"
PROBE_RES=""; [ -z "$PROBE" ] || PROBE_RES="$(outcome "$WORK/probe.out")"
echo "### outcomes"; echo "ddl: $DDL_RES $(grep -m1 ERROR "$WORK/ddl.out" || true)"
[ -z "$PROBE" ] || echo "probe: $PROBE_RES $(grep -m1 ERROR "$WORK/probe.out" || true)"
by() { echo "$SNAP" | sed '/^__DBREV_LOCKS__$/,$d' | awk -F'|' -v s="dbrev-lock-$RID-$1" -v pre="dbrev-lock-$RID-" '$1==s{gsub(pre,"",$5); print $5}'; }
# ok = the DDL (and probe) were seen waiting on a lock; otherwise the hold did not conflict or the run failed.
OKV=$OBSERVED; case "$DDL_RES" in error*|connect-failed|committed*) OKV=false ;; esac
[ "$HOLD_TX" = ok ] && [ "$PROBE_TX" = ok ] || { OKV=false; echo "注意:$HOLD_TX $PROBE_TX — 暫存庫已被改,後續實測請重建" >&2; }
printf '{"mode":"hold","ddl":"%s","ddl_blocked_by":"%s","probe":"%s","probe_blocked_by":"%s","observed":%s,"ok":%s}\n' \
  "$DDL_RES" "$(by ddl)" "$PROBE_RES" "$(by probe)" "$OBSERVED" "$OKV"
[ "$OKV" = true ]
