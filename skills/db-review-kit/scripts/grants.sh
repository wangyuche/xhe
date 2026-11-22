#!/bin/bash
# GRANT matrix: log in with each role's own LOGIN DSN and actually attempt every action (inside BEGIN … ROLLBACK).
#
#   grants.sh <name> --matrix FILE --dsn LABEL=DSN [--dsn LABEL=DSN]...
#
# Matrix file, one check per line ('#' comments and blank lines ignored):
#   <label> | <object> | <action> | <expect>
#   action: select | select(c1,c2) | insert | insert(c1,c2) | update(c1,c2) | delete | truncate | sql:<statement>
#           (sql: may use {obj} for the object; '|' inside the statement is fine)
#   expect: ok | 42501 | <other SQLSTATE>
# "ok" means the privilege check passed: success, or a later integrity / data error (23xxx / 22xxx, e.g. NOT NULL on
# INSERT … DEFAULT VALUES; 0A000 "referenced in a foreign key" for truncate). Any other error (42P01 missing table, 28P01 login failed …) is reported as error(<code>).
# Each check is its own connection (a real login; ALTER ROLE … SET applies). Nothing is committed.
# Output: PASS/FAIL lines, then `grants total=… pass=… fail=…`. Exit 1 if any FAIL, 4 if a DSN is not this container.
source "$(dirname "$0")/_common.sh"

usage() { sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[ $# -ge 1 ] || usage
NAME="$1"; check_name "$NAME"; shift
MATRIX=""; LABELS=""; DSNS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --matrix) MATRIX="${2:?}"; shift 2 ;;
    --dsn) kv="${2:?--dsn 需要 LABEL=DSN}"; LABELS="$LABELS ${kv%%=*}"; DSNS+=("${kv#*=}"); shift 2 ;;
    *) die "未知參數:$1" 2 ;;
  esac
done
[ -f "$MATRIX" ] || die "--matrix 檔案不存在" 2
[ ${#DSNS[@]} -gt 0 ] || die "至少一個 --dsn LABEL=DSN" 2
load_state "$NAME"; verify_container "$NAME"
guard_dsns "${DSNS[@]}"

dsn_for() { local i=0 l; for l in $LABELS; do [ "$l" = "$1" ] && { echo "${DSNS[$i]}"; return 0; }; i=$((i + 1)); done; return 1; }
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

stmt_for() { # <object> <action>
  local obj="$1" act="$2" cols
  case "$act" in
    select) echo "SELECT 1 FROM $obj LIMIT 0" ;;
    "select("*")") cols="${act#select(}"; echo "SELECT ${cols%)} FROM $obj LIMIT 0" ;;
    insert) echo "INSERT INTO $obj DEFAULT VALUES" ;;
    "insert("*")") cols="${act#insert(}"; cols="${cols%)}"
      echo "INSERT INTO $obj ($cols) VALUES ($(echo "$cols" | awk -F, '{for(i=1;i<=NF;i++) printf "%sDEFAULT", (i>1?", ":"")}'))" ;;
    "update("*")") cols="${act#update(}"; cols="${cols%)}"
      echo "UPDATE $obj SET $(echo "$cols" | awk -F, '{for(i=1;i<=NF;i++){gsub(/ /,"",$i); printf "%s%s = DEFAULT", (i>1?", ":""), $i}}') WHERE false" ;;
    delete) echo "DELETE FROM $obj WHERE false" ;;
    truncate) echo "TRUNCATE $obj" ;;
    sql:*) local s="${act#sql:}"; echo "${s//\{obj\}/$obj}" ;;
    *) return 1 ;;
  esac
}

TOTAL=0; PASSN=0; FAILN=0; LN=0
while IFS= read -r line || [ -n "$line" ]; do
  LN=$((LN + 1))
  case "$(trim "$line")" in ""|"#"*) continue ;; esac
  label="$(trim "${line%%|*}")"; rest="${line#*|}"
  obj="$(trim "${rest%%|*}")"; rest="${rest#*|}"
  expect="$(trim "${rest##*|}")"; act="$(trim "${rest%|*}")"
  [ -n "$label" ] && [ -n "$obj" ] && [ -n "$act" ] && [ -n "$expect" ] && [ "$act" != "$rest" ] || die "matrix 第 $LN 行格式錯誤:$line" 2
  dsn="$(dsn_for "$label")" || die "matrix 第 $LN 行的 label $label 沒有對應 --dsn" 2
  stmt="$(stmt_for "$obj" "$act")" || die "matrix 第 $LN 行不認得的動作:$act" 2
  out="$(printf 'BEGIN;\n%s;\nROLLBACK;\n' "$stmt" | psql_dsn "$dsn" -q 2>&1)" && rc=0 || rc=$?
  code="$(echo "$out" | sed -n 's/^\(psql:[^ ]* \)\{0,1\}ERROR: *\([0-9A-Z]\{5\}\):.*/\2/p' | head -1)"
  msg="$(echo "$out" | grep -m1 'ERROR' | sed 's/^psql:[^ ]* //' | cut -c1-160 || true)"
  if [ $rc -eq 0 ] && [ -z "$code" ]; then got="ok"
  elif [ -z "$code" ]; then got="error(?)"; msg="$(echo "$out" | head -2 | tr '\n' ' ' | cut -c1-160)"
  else
    case "$code" in
      42501) got="42501" ;;
      22*|23*) got="ok($code)" ;;
      0A000) if [ "$act" = truncate ]; then got="ok($code)"; else got="error($code)"; fi ;;  # FK check runs after the privilege check
      *) got="error($code)" ;;
    esac
  fi
  verdict=FAIL
  case "$expect" in
    ok) case "$got" in ok|ok\(*) verdict=PASS ;; esac ;;
    *) [ "$got" = "$expect" ] || [ "$got" = "ok($expect)" ] || [ "$got" = "error($expect)" ] && verdict=PASS ;;
  esac
  TOTAL=$((TOTAL + 1))
  if [ $verdict = PASS ]; then PASSN=$((PASSN + 1)); else FAILN=$((FAILN + 1)); fi
  echo "$verdict  $label | $obj | $act | expect=$expect got=$got${msg:+  [$msg]}"
done < "$MATRIX"
echo "grants total=$TOTAL pass=$PASSN fail=$FAILN"
[ $FAILN -eq 0 ]
