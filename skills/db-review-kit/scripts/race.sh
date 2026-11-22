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
# Sessions: application_name dbrev-race-A / -B, statement_timeout 30s, lock_timeout (default 10s, must exceed
# deadlock_timeout). Session ends roll back anything uncommitted.
# Last line: JSON {"deadlock":bool,"errors":{code:n},"checks":{"pass":n,"fail":n}}. Exit 1 if a CHECK fails.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
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
load_state "$NAME"; verify_container "$NAME"
guard_dsns "$DSN_A" "$DSN_B" "$CHK"

mkdir -p "$(name_dir "$NAME")"
W="$(mktemp -d "$(name_dir "$NAME")/race.XXXXXX")"
PA=""; PB=""
cleanup() {
  { exec 7>&- 8>&-; } 2>/dev/null || true
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
  (printf "SET application_name = 'dbrev-race-%s';\n" "$1"; cat "$3") \
    | PSQL_MERGE_STDERR=1 ST_OVERRIDE=30s LT_OVERRIDE="$LT" psql_dsn "$2" -q -v ON_ERROR_STOP=0 > "$4" 2>&1
}
start_session A "$DSN_A" "$W/a.fifo" "$W/a.out" & PA=$!
start_session B "$DSN_B" "$W/b.fifo" "$W/b.out" & PB=$!
exec 7>"$W/a.fifo"; exec 8>"$W/b.fifo"
trap '' PIPE   # a session whose psql already exited must not kill the script on the next write;
# FIFO writes use /usr/bin/printf: bash's builtin keeps a failed write buffered and flushes it into the next redirect
ENDED_A=""; ENDED_B=""

n=0; : > "$W/steps"
wait_marker() { # <outfile> <marker> <seconds> -> 0 found
  local t=0 lim; lim=$(awk -v w="$3" 'BEGIN{printf "%d", w*10}')
  while [ $t -lt "$lim" ]; do grep -qx "$2" "$1" 2>/dev/null && return 0; sleep 0.1; t=$((t + 1)); done
  return 1
}
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    A:*|B:*)
      s="${line%%:*}"; sql="${line#*:}"; sql="${sql# }"; n=$((n + 1))
      wok=0
      if [ "$s" = A ]; then f="$W/a.out"; [ -z "$ENDED_A" ] && /usr/bin/printf '%s\n\\echo __DBREV_STEP_%d__\n' "$sql" "$n" >&7 2>/dev/null && wok=1; [ $wok = 1 ] || ENDED_A=1
      else f="$W/b.out"; [ -z "$ENDED_B" ] && /usr/bin/printf '%s\n\\echo __DBREV_STEP_%d__\n' "$sql" "$n" >&8 2>/dev/null && wok=1; [ $wok = 1 ] || ENDED_B=1; fi
      if [ $wok = 0 ]; then st="not-sent(session $s ended)"
      elif wait_marker "$f" "__DBREV_STEP_${n}__" "$STEP_WAIT"; then st=done; else st=waiting; fi
      echo "$n|$s|$st|$sql" >> "$W/steps"
      echo "step $n $s: $sql → $st"
      ;;
    SLEEP:*) sleep "$(echo "${line#SLEEP:}" | tr -d ' ')" ;;
  esac
done < "$SCRIPT"
{ exec 7>&- 8>&-; } 2>/dev/null || true
k=0; while { kill -0 "$PA" 2>/dev/null || kill -0 "$PB" 2>/dev/null; } && [ $k -lt 160 ]; do sleep 0.25; k=$((k + 1)); done

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
  [ -n "$e" ] && echo "$e" | grep -oE '^[0-9A-Z]{5}' >> "$W/codes"
  if [ -z "$e" ] && [ "$fin" != finished ]; then e="no result (session ended; see trailing errors)"; fi
  echo "step $i $s ($st → $fin): ${e:-ok}"
done < "$W/steps"
# errors after the last marker (e.g. at session end)
for s in A B; do f="$W/a.out"; [ $s = B ] && f="$W/b.out"
  tail_err="$(awk '/^__DBREV_STEP_[0-9]+__$/{buf=""; next} /^psql: error:/{next} /(ERROR|FATAL): +[0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z][0-9A-Z]:/{sub(/^.*(ERROR|FATAL): +/,""); buf=buf (buf?"; ":"") $0} END{print buf}' "$f")"
  [ -z "$tail_err" ] || { echo "session $s trailing: $tail_err"; echo "$tail_err" | grep -oE '^[0-9A-Z]{5}' >> "$W/codes"; }
  # connection failures carry no SQLSTATE in psql's output ("psql: error: … FATAL: …")
  conn_err="$(grep -m1 '^psql: error:' "$f" | cut -c1-200 || true)"
  [ -z "$conn_err" ] || { echo "session $s connect failed: $conn_err"; echo connect >> "$W/codes"; }
done

CP=0; CF=0
while IFS= read -r line; do
  q="${line#CHECK:}"; exp="${q##*=>}"; q="${q%=>*}"
  exp="$(echo "$exp" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  got="$(printf '%s\n' "$q" | psql_dsn "$CHK" -qAt 2>&1 | tr '\n' ' ' | sed 's/[[:space:]]*$//')" || true
  if [ "$got" = "$exp" ]; then CP=$((CP + 1)); v=PASS; else CF=$((CF + 1)); v=FAIL; fi
  echo "CHECK $v:$q=> expected '$exp' got '$got'"
done < <(grep -E '^CHECK:' "$SCRIPT" || true)

ERRJSON="$(sort "$W/codes" | grep -v '^$' | uniq -c | awk '{printf "%s\"%s\":%d", (n++?",":""), $2, $1}')"
DL=false; grep -qx 40P01 "$W/codes" && DL=true
echo "{\"deadlock\":$DL,\"errors\":{${ERRJSON}},\"checks\":{\"pass\":$CP,\"fail\":$CF}}"
[ $CF -eq 0 ]
