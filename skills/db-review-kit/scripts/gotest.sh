#!/bin/bash
# Run the project's Go (integration) tests in an isolated env and summarise PASS / FAIL / SKIP (with skip reasons).
#
#   gotest.sh <name> --dir MODULE_DIR [--tags integration] [--env K=V]... [--run REGEX] [--p N]
#             [--timeout 540s] [-- packages...]          (packages default ./...)
#
# Env: env -i + PATH, HOME/TMPDIR in the kit tmp dir, GOCACHE/GOMODCACHE, GOTOOLCHAIN=local, GOFLAGS=-mod=readonly,
# PGPASSFILE=/dev/null, PGSERVICEFILE=/dev/null, Go download vars; plus ONLY the --env values given here.
# Every --env value that is a postgres:// URL must point at this container (127.0.0.1:<port>); DB-looking names
# with non-URL values are refused. DATABASE_URL / TEST_* / PG* from the calling shell are never inherited.
# Runs `go test -json -v -count=1 -timeout <t>`; full log in the kit tmp dir.
# Last line: JSON {"status":"PASS|FAIL|GAP",...}. Exit: 0 PASS, 1 FAIL, 5 GAP (any SKIP or zero tests), 2 usage, 4 refused.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
MOD=""; TAGS=""; RUN=""; PAR=""; TMO="540s"; ENVS=(); PKGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) MOD="${2:?}"; shift 2 ;;
    --tags) TAGS="${2:?}"; shift 2 ;;
    --env) ENVS+=("${2:?--env 需要 K=V}"); shift 2 ;;
    --run) RUN="${2:?}"; shift 2 ;;
    --p) PAR="${2:?}"; shift 2 ;;
    --timeout) TMO="${2:?}"; shift 2 ;;
    --) shift; PKGS=("$@")
        for a in ${PKGS[@]+"${PKGS[@]}"}; do case "$a" in -*) die "-- 後面只能放套件路徑,不能放 go 旗標($a)" 2 ;; esac; done
        break ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -n "$MOD" ] && [ -f "$MOD/go.mod" ] || die "--dir 要指向含 go.mod 的模組目錄" 2
MOD="$(cd "$MOD" && pwd)"
[ ${#PKGS[@]} -gt 0 ] || PKGS=("./...")
load_state "$NAME"; verify_container "$NAME"
[ ${#ENVS[@]} -eq 0 ] || check_extra_env "${ENVS[@]}"
for kv in ${ENVS[@]+"${ENVS[@]}"}; do
  case "${kv#*=}" in postgres://*|postgresql://*) echo "dsn-check ${kv%%=*}: $(dsnpy guard "$PORT" "${kv#*=}" | sed 's/^guard ok #1 //')" >&2 ;; esac
done

# Warn about DSNs hard-coded in test files that point somewhere other than an env var (e.g. localhost:5432).
HARD="$(cd "$MOD" && grep -rnE --include='*_test.go' '(postgres(ql)?://[^"`[:space:]]+|host=[^ "`]+|(localhost|127\.0\.0\.1|\[::1\]):5432)' . 2>/dev/null | head -20 || true)"
[ -z "$HARD" ] || { echo "警告:測試檔裡有寫死的連線字串(確認不會連到非本容器的資料庫):" >&2; echo "$HARD" | sed 's/^/  /' >&2; }

ensure_name_dir "$NAME"; D="$(name_dir "$NAME")"
LOG="$D/gotest-$(date +%Y%m%d-%H%M%S)-$$.jsonl"
ARGS=(test -json -v -count=1 -timeout "$TMO")
[ -n "$TAGS" ] && ARGS+=(-tags "$TAGS")
[ -n "$RUN" ] && ARGS+=(-run "$RUN")
[ -n "$PAR" ] && ARGS+=(-p "$PAR")
ISO_TMPDIR="$(mktemp -d "$D/gotmp.XXXXXX")"; export ISO_TMPDIR
cleanup() { rm -rf "$ISO_TMPDIR"; }
trap cleanup EXIT
echo "go ${ARGS[*]} ${PKGS[*]}  (dir=$MOD, log=$LOG)" >&2
START=$(date +%s)
set +e
(cd "$MOD" && run_iso "$NAME" ${ENVS[@]+"${ENVS[@]}"} -- go "${ARGS[@]}" "${PKGS[@]}") > "$LOG" 2>&1
GORC=$?
set -e
ELAPSED=$(( $(date +%s) - START ))
SUMMARY="$(python3 -I "$KIT_DIR/scripts/_gotest_parse.py" "$LOG" "$ELAPSED" "$GORC")"
python3 -I -c '
import json,sys
s=json.loads(sys.argv[1]); t=s["tests"]; u=s["subtests"]
print("tests: PASS %d / FAIL %d / SKIP %d (total %d); subtests: PASS %d / FAIL %d / SKIP %d; %ss; go rc=%s" % (
  t["pass"],t["fail"],t["skip"],t["total"],u["pass"],u["fail"],u["skip"],s["elapsed_s"],sys.argv[2]))
for k in s["skipped"]: print("SKIP %s %s: %s" % (k["package"],k["test"],k["reason"]))
for k in s["failed"]:
  print("FAIL %s %s" % (k["package"],k["test"]))
  for l in k["output"]: print("     "+l)
for g in s["gaps"]: print("GAP  "+g)
' "$SUMMARY" "$GORC" >&2
echo "$SUMMARY"
case "$(python3 -I -c 'import json,sys;print(json.loads(sys.argv[1])["status"])' "$SUMMARY")" in
  PASS) [ $GORC -eq 0 ] || exit 1; exit 0 ;;
  GAP) [ $GORC -eq 0 ] || exit 1; exit 5 ;;
  *) exit 1 ;;
esac
