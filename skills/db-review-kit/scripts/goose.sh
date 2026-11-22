#!/bin/bash
# goose CLI for db-reviewer, built at the project's go.mod version into the kit tmp dir and run in an isolated env.
#
#   goose.sh <name> run       --dir MIGDIR --table T --dsn DSN [--module DIR] -- <goose command...>
#   goose.sh <name> validate  --dir MIGDIR [--module DIR]
#   goose.sh <name> roundtrip --dir MIGDIR --table T --dsn STRICT_DSN [--dsn-allow ALLOW_DSN] --from V [--to V] [--module DIR]
#
# roundtrip: up-to <version before --from> → up-to <--to> → down-to <before> with STRICT_DSN (a guarded destructive
#   Down should be rejected) → if rejected, down-to <before> with ALLOW_DSN → up-to <--to>. Last line is a JSON summary.
# Only *.sql files are copied to a tmp dir and migrated; the project directory is never touched. goose runs with
# -env none when supported (newer goose would otherwise load ./.env) from the tmp dir, under env -i with GOFLAGS=-mod=readonly GOTOOLCHAIN=local.
# --module: directory holding go.mod (default: nearest go.mod above MIGDIR). Exit: 1 failure, 2 usage, 4 refused.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 2 ] || usage
NAME="$1"; check_name "$NAME"; SUB="$2"; shift 2
MIGDIR=""; TABLE=""; DSN=""; DSN_ALLOW=""; FROM=""; TO=""; MODULE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dir) MIGDIR="${2:?}"; shift 2 ;;
    --table) TABLE="${2:?}"; shift 2 ;;
    --dsn) DSN="${2:?}"; shift 2 ;;
    --dsn-allow) DSN_ALLOW="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --to) TO="${2:?}"; shift 2 ;;
    --module) MODULE="${2:?}"; shift 2 ;;
    --) shift; break ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -n "$MIGDIR" ] && [ -d "$MIGDIR" ] || die "--dir 必填且要是目錄" 2
MIGDIR="$(cd "$MIGDIR" && pwd)"

if [ -z "$MODULE" ]; then
  d="$MIGDIR"; while [ "$d" != "/" ] && [ ! -f "$d/go.mod" ]; do d="$(dirname "$d")"; done
  [ -f "$d/go.mod" ] || die "找不到 go.mod;用 --module 指定" 2
  MODULE="$d"
fi
grep -qE '^[[:space:]]*(replace[[:space:]]+)?github\.com/pressly/goose/v3([[:space:]]+v[^ ]+)?[[:space:]]*=>' "$MODULE/go.mod" \
  && die "go.mod 對 goose 有 replace;kit 只會編上游版本,行為可能不同 → goose 相關實測標缺口" 1
GOOSE_VER="$(awk '$1=="github.com/pressly/goose/v3" && $3!="=>"{print $2; exit} $1=="require" && $2=="github.com/pressly/goose/v3"{print $3; exit}' "$MODULE/go.mod")"
[ -n "$GOOSE_VER" ] || die "$MODULE/go.mod 沒有 github.com/pressly/goose/v3;goose 版本無法判定" 1
case "$GOOSE_VER" in v[0-9]*) ;; *) die "從 go.mod 讀到的 goose 版本不合法:$GOOSE_VER" 1 ;; esac

DIR="$(name_dir "$NAME")"; mkdir -p "$DIR/bin"
WORK="$(mktemp -d "$DIR/goose.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
GOOSE="$DIR/bin/goose-$GOOSE_VER"
if [ ! -x "$GOOSE" ]; then
  # GOBIN points into the kit tmp dir: nothing is installed globally. Driver tags trim the build to postgres.
  run_iso "$NAME" GOBIN="$WORK/gobin" -- go install \
    -tags 'no_clickhouse no_libsql no_mssql no_mysql no_sqlite3 no_vertica no_ydb no_turso no_spanner no_starrocks' \
    "github.com/pressly/goose/v3/cmd/goose@$GOOSE_VER" >&2 || die "goose $GOOSE_VER 編譯失敗" 1
  mv "$WORK/gobin/goose" "$GOOSE"
fi
echo "goose=$GOOSE_VER (from $MODULE/go.mod)" >&2
# -env (skip loading ./.env) exists only in newer goose CLIs; older ones never load .env, so the flag is just omitted.
ENVFLAG=(); "$GOOSE" -h 2>&1 | grep -q -- '-env string' && ENVFLAG=(-env none)

# Copy only versioned *.sql (read-only use of the project dir).
mkdir -p "$WORK/mig"
for f in "$MIGDIR"/*.sql; do [ -e "$f" ] && cp "$f" "$WORK/mig/"; done
GOMIG="$(cd "$MIGDIR" && ls | grep -E '^[0-9]+_.*\.go$' | grep -v '_test\.go$' || true)"
[ -z "$GOMIG" ] || echo "注意:有 Go migration(goose CLI 不會執行):$(echo $GOMIG)" >&2

goose_cmd() { # <dsn> <goose args...>
  local dsn="$1"; shift
  local d2; d2="$(dsnpy opts "$dsn" "-c statement_timeout=${GOOSE_STATEMENT_TIMEOUT:-300s}")"
  (cd "$WORK" && run_iso "$NAME" -- "$GOOSE" ${ENVFLAG[@]+"${ENVFLAG[@]}"} -dir "$WORK/mig" -table "$TABLE" postgres "$d2" "$@")
}

versions() { ls "$WORK/mig" | sed -n 's/^\([0-9][0-9]*\)_.*\.sql$/\1/p' | while read -r v; do echo $((10#$v)); done | sort -n; }

case "$SUB" in
  validate)
    (cd "$WORK" && run_iso "$NAME" -- "$GOOSE" ${ENVFLAG[@]+"${ENVFLAG[@]}"} -dir "$WORK/mig" validate)
    ;;
  run)
    [ -n "$TABLE" ] && [ -n "$DSN" ] || die "run 需要 --table 與 --dsn" 2
    [ $# -ge 1 ] || die "run 需要 -- <goose 指令>" 2
    load_state "$NAME"; verify_container "$NAME"; guard_dsns "$DSN"
    goose_cmd "$DSN" "$@"
    ;;
  roundtrip)
    [ -n "$TABLE" ] && [ -n "$DSN" ] && [ -n "$FROM" ] || die "roundtrip 需要 --table、--dsn、--from" 2
    case "$FROM$TO" in *[!0-9]*) die "--from / --to 只能是數字版本" 2 ;; esac
    load_state "$NAME"; verify_container "$NAME"
    guard_dsns "$DSN" ${DSN_ALLOW:+"$DSN_ALLOW"}
    FROM=$((10#$FROM)); [ -n "$TO" ] && TO=$((10#$TO)) || TO="$FROM"
    UPDSN0="${DSN_ALLOW:-$DSN}"
    versions | grep -qx "$FROM" || die "--dir 裡沒有版本 $FROM" 1
    versions | grep -qx "$TO" || die "--dir 裡沒有版本 $TO" 1
    [ "$TO" -ge "$FROM" ] || die "--to 不能小於 --from" 2
    CUR0="$(goose_cmd "$UPDSN0" version 2>&1 | sed -n 's/.*version:\{0,1\} *\([0-9][0-9]*\).*/\1/p' | tail -1)"
    [ -z "$CUR0" ] || [ "$CUR0" -le "$TO" ] || die "資料庫目前在版本 $CUR0,高於 --to $TO;roundtrip 會連帶 down 審查範圍外的 migration。先用 goose.sh run 退到 ≤ $TO,或改 --to" 1
    BEFORE="$(versions | awk -v f="$FROM" '$1<f{b=$1} END{print b+0}')"
    UPDSN="${DSN_ALLOW:-$DSN}"
    step() { # <label> <dsn-label> <dsn> <args...>; prints output, sets RC
      local label="$1" dl="$2" dsn="$3"; shift 3
      echo "== $label (dsn=$dl): goose $*"
      local out; out="$(goose_cmd "$dsn" "$@" 2>&1)" && RC=0 || RC=$?
      echo "$out" | sed 's/^/   /'; echo "   rc=$RC"
      LAST_OUT="$out"
    }
    cur_version() { goose_cmd "$UPDSN" version 2>&1 | sed -n 's/.*version:\{0,1\} *\([0-9][0-9]*\).*/\1/p' | tail -1; }
    up1="skipped"; down_strict=""; down_allow="skipped"; up2=""; reject_msg=""
    if [ "$BEFORE" -gt 0 ]; then
      step "1 up-to before" "$( [ -n "$DSN_ALLOW" ] && echo allow || echo strict)" "$UPDSN" up-to "$BEFORE"
      [ $RC -eq 0 ] || { echo '{"ok":false,"failed":"up-to-before"}'; exit 1; }
    fi
    step "2 up-to target" "$( [ -n "$DSN_ALLOW" ] && echo allow || echo strict)" "$UPDSN" up-to "$TO"
    [ $RC -eq 0 ] && up1="ok" || up1="failed"
    if [ "$up1" = "ok" ]; then
      step "3 down-to before (no flag)" strict "$DSN" down-to "$BEFORE"
      if [ $RC -eq 0 ]; then down_strict="ok"; else
        down_strict="rejected"
        reject_msg="$(echo "$LAST_OUT" | grep -oE 'ERROR: .*\(SQLSTATE [0-9A-Z]{5}\)' | tail -1 | cut -c1-300)"
        [ -n "$reject_msg" ] || reject_msg="$(echo "$LAST_OUT" | grep -m1 -iE 'error|failed' | cut -c1-300)"
        echo "   version after rejected down: $(cur_version)"
        if [ -n "$DSN_ALLOW" ]; then
          step "4 down-to before (with flag)" allow "$DSN_ALLOW" down-to "$BEFORE"
          [ $RC -eq 0 ] && down_allow="ok" || down_allow="failed"
        else down_allow="no-allow-dsn"; fi
      fi
      if [ "$down_strict" = "ok" ] || [ "$down_allow" = "ok" ]; then
        step "5 up-to target again" "$( [ -n "$DSN_ALLOW" ] && echo allow || echo strict)" "$UPDSN" up-to "$TO"
        [ $RC -eq 0 ] && up2="ok" || up2="failed"
      else up2="not-run"; fi
    else down_strict="not-run"; up2="not-run"; fi
    FINAL="$(cur_version)"
    OK=false
    [ "$up1" = "ok" ] && [ "$up2" = "ok" ] && [ "$FINAL" = "$TO" ] && OK=true
    python3 -I -c 'import json,sys
k=["before","from","to","up","down_no_flag","down_with_flag","up_again","final_version","reject_message"]
d=dict(zip(k,sys.argv[1:10])); d["ok"]=sys.argv[10]=="true"
for n in ("before","from","to"): d[n]=int(d[n])
print(json.dumps(d,ensure_ascii=False))' "$BEFORE" "$FROM" "$TO" "$up1" "$down_strict" "$down_allow" "$up2" "$FINAL" "$reject_msg" "$OK"
    [ "$OK" = true ]
    ;;
  *) usage ;;
esac
