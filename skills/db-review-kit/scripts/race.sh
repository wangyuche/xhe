#!/bin/bash
# Two sessions interleaved step by step: detect deadlocks (40P01), unique violations on retries (23505),
# serialization failures (40001), and check invariants afterwards (e.g. no double credit, balance = ledger sum).
#
#   race.sh <name> --script FILE --dsn A=DSN --dsn B=DSN [--check-dsn DSN] [--step-wait 1] [--lock-timeout 10s]
#
# Script lines ('#' comments, blank lines ignored; each statement on one line):
#   SETUP: <sql>              run before the sessions start (check DSN), e.g. insert test rows
#   A: <sql>  /  B: <sql>     sent to that session in order; if it does not finish within --step-wait seconds it is
#                             marked "waiting" and the next step is sent (the session keeps waiting in the background)
#   SLEEP: <seconds>
#   CHECK: <sql> => <expected> run after both sessions end (check DSN); output compared as trimmed text
#                             (split at the LAST "=>": the expected text itself cannot contain "=>")
# Sessions: application_name dbrev-race-<pid>-A / -B (cancelled on exit), statement_timeout 30s, lock_timeout (default 10s, must exceed
# deadlock_timeout). Session ends roll back anything uncommitted.
# Last line: JSON {"deadlock":bool,"errors":{code:n},"checks":{"pass":n,"fail":n}}. Exit 1 if a CHECK fails.
source "$(dirname "$0")/_common.sh"
RID=$$

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
SCRIPT=""; DSN_A=""; DSN_B=""; CHK=""; STEP_WAIT=1; LT="10s"
while [ $# -gt 0 ]; do
  case "$1" in
    --script) SCRIPT="${2:?}"; shift 2 ;;
    --dsn) kv="${2:?}"; case "$kv" in A=*) DSN_A="${kv#A=}" ;; B=*) DSN_B="${kv#B=}" ;; *) die "--dsn 要寫 A=… 或 B=…" 2 ;; esac; shift 2 ;;
    --check-dsn) CHK="${2:?}"; shift 2 ;;
    --step-wait) STEP_WAIT="${2:?}"; shift 2 ;;
    --lock-timeout) LT="${2:?}"; shift 2 ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -f "$SCRIPT" ] && [ -n "$DSN_A" ] && [ -n "$DSN_B" ] || die "需要 --script、--dsn A=…、--dsn B=…" 2
[ -n "$CHK" ] || CHK="$DSN_A"
case "$LT" in *[0-9]ms|*[0-9]s|*[0-9]min) ;; *) die "--lock-timeout 要帶單位,例如 10s" 2 ;; esac
printf '%s' "$LT" | grep -Eq '^[0-9]+(ms|s|min)$' || die "--lock-timeout 格式例:10s" 2
# SETUP / A / B are checked whole; CHECK only up to its LAST "=>" (the rest is the expected text, never sent to psql).
# The check is per raw line (no cross-line lexing), so lines sent to different sessions cannot hide each other.
bad="$( { grep -E '^(SETUP|A|B):' "$SCRIPT" | sed -E 's/^(SETUP|A|B):[[:space:]]*//' || true; grep -E '^CHECK:' "$SCRIPT" | sed -E 's/^CHECK:[[:space:]]*//; s/(.*)=>.*$/\1/' || true; } \
  | python3 -I "$KIT_DIR/scripts/_txcheck.py" --connect)" \
  || { trc=$?; die "腳本不允許:$bad" "$trc"; }
nosemi="$(grep -E '^(A|B):' "$SCRIPT" | sed -E 's/^(A|B):[[:space:]]*//' | python3 -I "$KIT_DIR/scripts/_txcheck.py" --ends-with-semicolon || true)"
[ -z "$nosemi" ] || die "A: / B: 的每一行都要以 ; 結尾(否則 psql 會先印標記、語句卻還沒送出):$nosemi" 2
unknown="$(grep -vE '^[[:space:]]*($|#)|^(SETUP|A|B|SLEEP|CHECK):' "$SCRIPT" | head -1 || true)"
[ -z "$unknown" ] || die "不認得的腳本行(只接受 SETUP: / A: / B: / SLEEP: / CHECK:、空行、# 註解):$unknown" 2
nocmp="$(grep -E '^CHECK:' "$SCRIPT" | grep -v '=>' | head -1 || true)"
[ -z "$nocmp" ] || die "CHECK 行要寫成 CHECK: <sql> => <預期>:$nocmp" 2
bad_sleep="$(grep -E '^SLEEP:' "$SCRIPT" | sed 's/^SLEEP:[[:space:]]*//;s/[[:space:]]*$//' | grep -vE '^[0-9]+(\.[0-9]+)?$' | head -1 || true)"
[ -z "$bad_sleep$(grep -E '^SLEEP:[[:space:]]*$' "$SCRIPT" || true)" ] || die "SLEEP: 的值要是秒數(例如 0.5):${bad_sleep:-空白}" 2
printf '%s' "$STEP_WAIT" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || die "--step-wait 要是秒數(例如 1 或 0.5)" 2
load_state "$NAME"; verify_container "$NAME"
guard_dsns "$DSN_A" "$DSN_B" "$CHK"
lt_ms=$(printf '%s' "$LT" | awk '/ms$/{print $0+0; next} /min$/{print ($0+0)*60000; next} {print ($0+0)*1000}')
DT="$(printf "SELECT setting::int * CASE unit WHEN 's' THEN 1000 WHEN 'min' THEN 60000 ELSE 1 END FROM pg_settings WHERE name = 'deadlock_timeout';\n" | psql_dsn "$CHK" -qAt 2>/dev/null || true)"
case "$DT" in ""|*[!0-9]*) DT=1000 ;; esac
[ "$lt_ms" -gt "$DT" ] || die "--lock-timeout 要大於 deadlock_timeout(${DT}ms),否則 deadlock 會被當成 lock timeout" 2
# cleanup cancels both sessions through the check DSN: it must be allowed to signal other roles' backends
priv="$(printf "SELECT rolsuper OR pg_has_role(current_user, 'pg_signal_backend', 'member') FROM pg_roles WHERE rolname = current_user;\n" | psql_dsn "$CHK" -qAt 2>&1 || true)"
ua="$(dsnpy field "$DSN_A" user)"; ub="$(dsnpy field "$DSN_B" user)"; uc="$(dsnpy field "$CHK" user)"
if [ "$priv" != t ] && { [ "$ua" != "$ub" ] || [ "$ua" != "$uc" ]; }; then   # same role may cancel its own backends
  die "--check-dsn 要是 superuser(或 pg_signal_backend),才能在中斷時取消兩個 session;請給 superuser DSN" 2
fi

mkdir -p "$(name_dir "$NAME")"
W="$(mktemp -d "$(name_dir "$NAME")/race.XXXXXX")"
PA=""; PB=""
cleanup() {
  { exec 7>&- 8>&-; } 2>/dev/null || true
  # cancel our sessions in the container (they may still wait on locks after an interrupt)
  printf "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name IN ('dbrev-race-%s-A', 'dbrev-race-%s-B') AND pid <> pg_backend_pid();\n" "$RID" "$RID" \
    | psql_dsn "$CHK" -qAt >/dev/null 2>&1 || true
  local p k
  for p in $PA $PB; do
    k=0; while kill -0 "$p" 2>/dev/null && [ $k -lt 40 ]; do sleep 0.25; k=$((k + 1)); done
    kill "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true
  done
  rm -rf "$W"
}
trap cleanup EXIT

# SETUP
grep -E '^SETUP:' "$SCRIPT" | sed 's/^SETUP:[[:space:]]*//' > "$W/setup.sql" || true
if [ -s "$W/setup.sql" ]; then
  psql_dsn "$CHK" -q < "$W/setup.sql" > "$W/setup.out" 2>&1 || { cat "$W/setup.out" >&2; die "SETUP 失敗" 1; }
fi

mkfifo "$W/a.fifo" "$W/b.fifo"
start_session() { # <label> <dsn> <fifo> <out>
  # the END sentinel is written as soon as psql exits (cat may linger until its next write)
  (printf "SET application_name = 'dbrev-race-%s-%s';\n" "$RID" "$1"; cat "$3") \
    | { PSQL_KIT_WINS=1 PSQL_MERGE_STDERR=1 ST_OVERRIDE=30s LT_OVERRIDE="$LT" psql_dsn "$2" -q -v ON_ERROR_STOP=0; echo "__DBREV_SESSION_END__"; } > "$4" 2>&1
}
start_session A "$DSN_A" "$W/a.fifo" "$W/a.out" & PA=$!
start_session B "$DSN_B" "$W/b.fifo" "$W/b.out" & PB=$!
exec 7<>"$W/a.fifo"; exec 8<>"$W/b.fifo"   # read-write open never blocks, even if a session died before opening its FIFO
trap '' PIPE   # a session whose psql already exited must not kill the script on the next write;
# FIFO writes use /usr/bin/printf: bash's builtin keeps a failed write buffered and flushes it into the next redirect
ENDED_A=""; ENDED_B=""

n=0; : > "$W/steps"
wait_marker() { # <outfile> <marker> <seconds> -> 0 found
  local t=0 lim; lim=$(awk -v w="$3" 'BEGIN{l = int(w * 10 + 0.999); if (l < 1) l = 1; printf "%d", l}')
  while [ $t -lt "$lim" ]; do grep -qx "$2" "$1" 2>/dev/null && return 0; sleep 0.1; t=$((t + 1)); done
  return 1
}
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    A:*|B:*)
      s="${line%%:*}"; sql="${line#*:}"; sql="${sql# }"; n=$((n + 1))
      wok=0
      if [ "$s" = A ] && { ! kill -0 "$PA" 2>/dev/null || grep -qx '__DBREV_SESSION_END__' "$W/a.out"; }; then ENDED_A=1; fi
      if [ "$s" = B ] && { ! kill -0 "$PB" 2>/dev/null || grep -qx '__DBREV_SESSION_END__' "$W/b.out"; }; then ENDED_B=1; fi
      if [ "$s" = A ]; then f="$W/a.out"; [ -z "$ENDED_A" ] && /usr/bin/printf '%s\n\\echo __DBREV_STEP_%d__\n' "$sql" "$n" >&7 2>/dev/null && wok=1; [ $wok = 1 ] || ENDED_A=1
      else f="$W/b.out"; [ -z "$ENDED_B" ] && /usr/bin/printf '%s\n\\echo __DBREV_STEP_%d__\n' "$sql" "$n" >&8 2>/dev/null && wok=1; [ $wok = 1 ] || ENDED_B=1; fi
      if [ $wok = 0 ]; then st="not-sent(session $s ended)"
      elif wait_marker "$f" "__DBREV_STEP_${n}__" "$STEP_WAIT"; then st=done; else st=waiting; fi
      echo "$n|$s|$st|$sql" >> "$W/steps"
      echo "step $n $s: $sql → $st"
      ;;
    SLEEP:*) sleep "$(printf '%s' "${line#SLEEP:}" | tr -d '[:space:]')" ;;
  esac
done < "$SCRIPT"
{ exec 7>&- 8>&-; } 2>/dev/null || true
# wait for both sessions: every queued step may wait up to statement_timeout (30 s)
lim=$(( (n * 30 + 10) * 4 )); k=0
while { kill -0 "$PA" 2>/dev/null || kill -0 "$PB" 2>/dev/null; } && [ $k -lt $lim ]; do sleep 0.25; k=$((k + 1)); done
SESS_LEFT=""
if kill -0 "$PA" 2>/dev/null || kill -0 "$PB" 2>/dev/null; then
  printf "SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name IN ('dbrev-race-%s-A', 'dbrev-race-%s-B');\n" "$RID" "$RID" \
    | psql_dsn "$CHK" -qAt >/dev/null 2>&1 || true
  k=0; while { kill -0 "$PA" 2>/dev/null || kill -0 "$PB" 2>/dev/null; } && [ $k -lt 40 ]; do sleep 0.25; k=$((k + 1)); done
  SESS_LEFT=1
fi

# Attribute each ERROR to the step whose marker follows it in that session's output.
seg_errors() { # <outfile> <step> -> "CODE message" lines between the previous marker and this one
  awk -v want="__DBREV_STEP_$2__" '
    /^__DBREV_STEP_[0-9]+__$/ { if ($0 == want) { print buf; found=1; exit } buf=""; next }
    /(ERROR|FATAL): +[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]:/ { sub(/^.*(ERROR|FATAL): +/, ""); buf = buf (buf ? "; " : "") $0 }
    ' "$1"
}
echo "### results"
: > "$W/codes"
while IFS='|' read -r i s st sql; do
  f="$W/a.out"; [ "$s" = B ] && f="$W/b.out"
  if grep -qx "__DBREV_STEP_${i}__" "$f"; then fin=finished; else fin="never-finished"; fi
  e="$(seg_errors "$f" "$i")"
  if [ -z "$e" ] && [ "$fin" != finished ]; then e="no result (session ended; see trailing errors)"; fi
  echo "step $i $s ($st → $fin): ${e:-ok}"
done < "$W/steps"
# errors after the last marker (e.g. at session end)
for s in A B; do f="$W/a.out"; [ $s = B ] && f="$W/b.out"
  tail_err="$(awk '/^__DBREV_STEP_[0-9]+__$/{buf=""; next} /^psql: error:/{next} /(ERROR|FATAL): +[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]:/{sub(/^.*(ERROR|FATAL): +/,""); buf=buf (buf?"; ":"") $0} END{print buf}' "$f")"
  [ -z "$tail_err" ] || echo "session $s trailing: $tail_err"
  # count every SQLSTATE once, straight from the session output (not from joined message text)
  { grep -E '(ERROR|FATAL): +[0-9A-Z]{5}:' "$f" || true; } | { grep -v '^psql: error:' || true; } \
    | sed -E 's/.*(ERROR|FATAL): +([0-9A-Z]{5}):.*/\2/' >> "$W/codes"
  # connection failures carry no SQLSTATE in psql's output ("psql: error: … FATAL: …")
  conn_err="$(grep -m1 '^psql: error:' "$f" | cut -c1-200 || true)"
  [ -z "$conn_err" ] || { echo "session $s connect failed: $conn_err"; echo connect >> "$W/codes"; }
done

CP=0; CF=0
if kill -0 "$PA" 2>/dev/null || kill -0 "$PB" 2>/dev/null; then
  echo "sessions still running after cancel: CHECK skipped" >&2
  echo '{"deadlock":null,"errors":{},"checks":{"pass":0,"fail":0},"ok":false,"error":"sessions did not finish"}'
  exit 1
fi
[ -z "$SESS_LEFT" ] || echo "注意:session 超過等待上限而被取消,之後的步驟沒有結果" >&2
while IFS= read -r line; do
  q="${line#CHECK:}"; exp="${q##*=>}"; q="${q%=>*}"
  exp="$(echo "$exp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  crc=0
  printf '%s\n' "$q" | psql_dsn "$CHK" -qAt > "$W/check.out" 2>"$W/check.err" || crc=$?   # stdout only; NOTICE / WARNING go to check.err
  got="$(tr '\n' ' ' < "$W/check.out" | sed 's/[[:space:]]*$//')"
  [ "$got" = "$exp" ] && [ $crc -eq 0 ] || { [ ! -s "$W/check.err" ] || got="$got [stderr: $(tr '\n' ' ' < "$W/check.err" | cut -c1-200)]"; }
  if [ $crc -eq 0 ] && [ "$got" = "$exp" ]; then CP=$((CP + 1)); v=PASS; else CF=$((CF + 1)); v=FAIL; fi
  echo "CHECK $v:$q=> expected '$exp' got '$got'"
done < <(grep -E '^CHECK:' "$SCRIPT" || true)

ERRJSON="$( { grep -v '^$' "$W/codes" || true; } | sort | uniq -c | awk '{printf "%s\"%s\":%d", (n++?",":""), $2, $1}')"
DL=false; grep -qx 40P01 "$W/codes" && DL=true
echo "{\"deadlock\":$DL,\"errors\":{${ERRJSON}},\"checks\":{\"pass\":$CP,\"fail\":$CF}}"
[ $CF -eq 0 ]
