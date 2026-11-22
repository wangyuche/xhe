#!/bin/bash
# EXPLAIN (ANALYZE, BUFFERS) once, then N timed runs for p50 / p95 / max (server-side planning + execution time).
#
#   explain.sh <name> --dsn DSN (--query 'SQL' | --file F) [--runs 20] [--target-ms 50]
#
# Exactly one statement: ';' is not allowed anywhere except one trailing ';' (even inside literals / comments;
# rewrite such literals, e.g. chr(59)). Every run is wrapped in BEGIN … ROLLBACK, so DML under test leaves no rows (sequence / identity values still advance). Timing comes from
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
case "$RUNS" in *[!0-9]*|"") die "--runs 要是 ≥ 1 的整數" 2 ;; esac
RUNS=$((10#$RUNS)); [ "$RUNS" -ge 1 ] || die "--runs 要是 ≥ 1 的整數" 2
[ -z "$TARGET" ] || printf '%s' "$TARGET" | grep -Eq '^[0-9]+(\.[0-9]+)?$' || die "--target-ms 要是數字(毫秒)" 2
load_state "$NAME"; verify_container "$NAME"
guard_dsns "$DSN"
# drop trailing blank / "--" comment lines, then one trailing ';'
Q="$(printf '%s\n' "$Q" | awk '{ l[NR] = $0 } END { n = NR; while (n > 0 && (l[n] ~ /^[[:space:]]*$/ || l[n] ~ /^[[:space:]]*--/)) n--; for (i = 1; i <= n; i++) print l[i] }' \
     | sed -e 's/[[:space:]]*$//' -e '$ s/;[[:space:]]*--[^'"'"']*$/;/' -e '$ s/;$//')"
case "$Q" in *";"*) die "--query / --file 只能放一個語句(EXPLAIN 只會套在第一個)" 2 ;; esac
bad="$(printf '%s\n' "$Q" | python3 -I "$KIT_DIR/scripts/_txcheck.py")" || die "查詢裡有交易控制或 psql 指令($bad),無法保證 ROLLBACK" 2

echo "### plan: EXPLAIN (ANALYZE, BUFFERS)"
PLAN="$(printf 'BEGIN;\nEXPLAIN (ANALYZE, BUFFERS) %s\n;\nROLLBACK;\n' "$Q" | psql_dsn "$DSN" -q 2>&1)" && PRC=0 || PRC=$?
printf '%s\n' "$PLAN"
if [ $PRC -ne 0 ]; then
  python3 -I -c 'import json,sys; print(json.dumps({"runs_completed": 0, "ok": False, "error": sys.argv[1]}, ensure_ascii=False, separators=(",", ":")))' \
    "$(printf '%s\n' "$PLAN" | grep -m1 -E 'ERROR' | cut -c1-200 || true)"
  exit 1
fi
SCRIPT="$(i=0; while [ $i -le "$RUNS" ]; do printf 'BEGIN;\nEXPLAIN (ANALYZE, TIMING OFF, SUMMARY ON) %s\n;\nROLLBACK;\n' "$Q"; i=$((i + 1)); done)"
RAW="$(printf '%s\n' "$SCRIPT" | psql_dsn "$DSN" -qAt 2>&1)" && PRC=0 || PRC=$?
TIMES="$(printf '%s\n' "$RAW" | awk '
  /^Planning Time:/ { p = $3 }
  /^Execution Time:/ { n++; if (n > 1) printf "%.3f\n", p + $3 }')"
if [ $PRC -ne 0 ]; then
  python3 -I -c 'import json,sys; print(json.dumps({"runs_completed": len([x for x in sys.argv[1].split() if x]), "ok": False, "error": sys.argv[2]}, ensure_ascii=False, separators=(",", ":")))' \
    "$TIMES" "$(printf '%s\n' "$RAW" | grep -m1 -E 'ERROR' | cut -c1-200 || true)"
  exit 1
fi
[ -n "$TIMES" ] || { echo '{"runs":0,"ok":false,"error":"no timings parsed"}'; exit 1; }
echo "$TIMES" | sort -n | awk -v runs="$RUNS" -v target="$TARGET" '
  { v[NR] = $1 }
  END {
    if (NR == 0) { print "{\"runs\":0,\"ok\":false}"; exit 1 }
    i50 = int((NR * 50 + 99) / 100); i95 = int((NR * 95 + 99) / 100)
    ok = (target == "" || v[i95] <= target + 0) ? "true" : "false"
    printf "{\"runs\":%d,\"p50_ms\":%.3f,\"p95_ms\":%.3f,\"max_ms\":%.3f,\"target_ms\":%s,\"ok\":%s}\n", NR, v[i50], v[i95], v[NR], (target == "" ? "null" : sprintf("%g", target + 0)), ok
    exit (ok == "true") ? 0 : 1
  }'
