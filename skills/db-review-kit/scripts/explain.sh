#!/bin/bash
# EXPLAIN (ANALYZE, BUFFERS) once, then N timed runs for p50 / p95 / max (server-side planning + execution time).
#
#   explain.sh <name> --dsn DSN (--query 'SQL' | --file F) [--runs 20] [--target-ms 50]
#
# Every run is wrapped in BEGIN … ROLLBACK, so DML under test changes nothing. Timing comes from
# EXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON): Planning Time + Execution Time, excluding network and client.
# One warm-up run is excluded. Last line: JSON {"runs":…,"p50_ms":…,"p95_ms":…,"max_ms":…,"target_ms":…,"ok":…}.
# Exit 1 if --target-ms is given and p95 exceeds it.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
DSN=""; Q=""; RUNS=20; TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dsn) DSN="${2:?}"; shift 2 ;;
    --query) Q="${2:?}"; shift 2 ;;
    --file) [ -f "${2:?}" ] || die "檔案不存在:$2" 2; Q="$(cat "$2")"; shift 2 ;;
    --runs) RUNS="${2:?}"; shift 2 ;;
    --target-ms) TARGET="${2:?}"; shift 2 ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -n "$DSN" ] && [ -n "$Q" ] || die "需要 --dsn 與 --query / --file" 2
case "$RUNS" in *[!0-9]*|""|0) die "--runs 要是 ≥ 1 的整數" 2 ;; esac
load_state "$NAME"; verify_container "$NAME"
guard_dsns "$DSN"
Q="$(printf '%s' "$Q" | sed -e 's/[[:space:]]*$//' -e '$ s/;$//')"

echo "### plan: EXPLAIN (ANALYZE, BUFFERS)"
printf 'BEGIN;\nEXPLAIN (ANALYZE, BUFFERS) %s\n;\nROLLBACK;\n' "$Q" | psql_dsn "$DSN" -q
SCRIPT="$(i=0; while [ $i -le "$RUNS" ]; do printf 'BEGIN;\nEXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) %s\n;\nROLLBACK;\n' "$Q"; i=$((i + 1)); done)"
TIMES="$(printf '%s\n' "$SCRIPT" | psql_dsn "$DSN" -qAt | awk '
  /^Planning Time:/ { p = $3 }
  /^Execution Time:/ { n++; if (n > 1) printf "%.3f\n", p + $3 }')"
[ -n "$TIMES" ] || { echo '{"runs":0,"ok":false,"error":"no timings parsed"}'; exit 1; }
echo "$TIMES" | sort -n | awk -v runs="$RUNS" -v target="$TARGET" '
  { v[NR] = $1 }
  END {
    if (NR == 0) { print "{\"runs\":0,\"ok\":false}"; exit 1 }
    i50 = int((NR * 50 + 99) / 100); i95 = int((NR * 95 + 99) / 100)
    ok = (target == "" || v[i95] <= target + 0) ? "true" : "false"
    printf "{\"runs\":%d,\"p50_ms\":%.3f,\"p95_ms\":%.3f,\"max_ms\":%.3f,\"target_ms\":%s,\"ok\":%s}\n", NR, v[i50], v[i95], v[NR], (target == "" ? "null" : target), ok
    exit (ok == "true") ? 0 : 1
  }'
