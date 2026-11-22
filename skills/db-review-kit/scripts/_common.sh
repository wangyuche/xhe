# db-review-kit shared helpers (sourced by the other scripts). Compatible with macOS bash 3.2.
# Exit codes used across the kit: 1 failure, 2 usage, 3 docker not running, 4 isolation/guard refusal, 5 test gap.
set -euo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
_sys_tmp="${TMPDIR:-/tmp}"; _sys_tmp="${_sys_tmp%/}"
KIT_TMP="${DB_REVIEW_KIT_TMP:-$_sys_tmp/db-review-kit}"
KIT_TMP="${KIT_TMP%/}"
DBREV_STATEMENT_TIMEOUT="${DBREV_STATEMENT_TIMEOUT:-60s}"
DBREV_LOCK_TIMEOUT="${DBREV_LOCK_TIMEOUT:-5s}"

die() { echo "錯誤:$1" >&2; exit "${2:-1}"; }
dsnpy() { python3 -I "$KIT_DIR/scripts/_dsn.py" "$@"; }
mask() { dsnpy mask "$1"; }

check_name() {
  [ -n "${1:-}" ] || die "缺少 <name>" 2
  case "$1" in
    *[!a-z0-9-]*|-*) die "<name> 只能是小寫英文、數字與連字號(不能以連字號開頭):$1" 2 ;;
  esac
}

name_dir() { echo "$KIT_TMP/$1"; }
state_file() { echo "$KIT_TMP/$1/state.env"; }
rand_hex() { od -An -tx1 -N"${1:-12}" /dev/urandom | tr -d ' \n'; }

# Refuse anything but a local docker daemon (unix socket / named pipe). Exit 4 = refusal, 3 = daemon not running.
require_local_docker() {
  if [ -n "${DOCKER_HOST:-}" ]; then
    case "$DOCKER_HOST" in
      unix://*) ;;
      *) die "DOCKER_HOST=$DOCKER_HOST 不是本機 socket;db-review-kit 只用本機 docker" 4 ;;
    esac
  else
    local ctx ep
    ctx="$(docker context show 2>/dev/null || true)"
    ep="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
    case "$ep" in
      unix://*|npipe://*) ;;
      "") die "無法取得 docker context(${ctx:-?})的端點;docker 沒安裝或設定損壞" 3 ;;
      *) die "docker context ${ctx:-?} 指向 $ep,不是本機;db-review-kit 只用本機 docker" 4 ;;
    esac
  fi
  docker info >/dev/null 2>&1 || die "Docker 沒有在執行" 3
}

# Load state written by `pg.sh up`: CONTAINER PORT IMAGE SUPERUSER SUPERPASS DBS ROLES
load_state() {
  require_local_docker
  local f; f="$(state_file "$1")"
  [ -f "$f" ] || die "找不到 $1 的容器狀態($f);先 pg.sh up $1" 1
  # shellcheck disable=SC1090
  . "$f"
  case "$CONTAINER" in "dbrev-$1-"*) ;; *) die "狀態檔的容器名稱不符前綴 dbrev-$1-:$CONTAINER" 4 ;; esac
}

# Container must exist, carry label dbrev=<name>, and have the expected prefix.
verify_container() {
  local name="$1" label
  label="$(docker inspect -f '{{ index .Config.Labels "dbrev" }}' "$CONTAINER" 2>/dev/null || true)"
  [ "$label" = "$name" ] || die "容器 $CONTAINER 不存在或 label dbrev 不是 $name" 4
}

# Guard: every DSN must point at 127.0.0.1:<this container's port>. Exit 4 on failure.
guard_dsns() {
  local out rc=0
  out="$(dsnpy guard "$PORT" "$@")" || rc=$?
  if [ $rc -ne 0 ]; then echo "$out" >&2; die "DSN 不是指向本容器 127.0.0.1:$PORT,拒絕執行" 4; fi
  [ -n "${QUIET_GUARD:-}" ] || echo "$out" >&2
}

# Run psql inside the container against a guarded host DSN.
# Kit defaults for statement_timeout / lock_timeout come first in `options`, so a DSN that sets its own wins.
# usage: psql_dsn <dsn> [psql args...]   (SQL from stdin unless -c/-f given)
psql_dsn() {
  local dsn="$1"; shift
  QUIET_GUARD=1 guard_dsns "$dsn"
  local idsn
  idsn="$(dsnpy opts "$dsn" "-c statement_timeout=${ST_OVERRIDE:-$DBREV_STATEMENT_TIMEOUT} -c lock_timeout=${LT_OVERRIDE:-$DBREV_LOCK_TIMEOUT}")"
  idsn="$(dsnpy internal "$idsn")"
  if [ -n "${PSQL_MERGE_STDERR:-}" ]; then
    # docker exec forwards stdout and stderr on separate channels (their relative order is lost); merge inside the container.
    docker exec -i "$CONTAINER" env -i PATH=/usr/local/bin:/usr/bin:/bin PGPASSFILE=/dev/null PGSERVICEFILE=/dev/null \
      sh -c 'exec psql "$@" 2>&1' psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$idsn" "$@"
  else
    docker exec -i "$CONTAINER" env -i PATH=/usr/local/bin:/usr/bin:/bin PGPASSFILE=/dev/null PGSERVICEFILE=/dev/null \
      psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$idsn" "$@"
  fi
}

# ---------- isolated environment for go / goose ----------
# Never inherits DATABASE_URL, TEST_*, PG*, GOOSE_* etc.: everything goes through env -i plus an allowlist.
GO_NET_VARS="GOPROXY GOSUMDB GOPRIVATE GONOSUMDB GONOPROXY GOINSECURE"
PROXY_VARS="HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy"

# Prints KEY=VALUE lines of the isolated base environment (one per line).
iso_base_env() {
  local name="$1" d; d="$(name_dir "$name")"
  mkdir -p "$d/home" "$d/gotmp"
  local gocache gomodcache v val
  # The user's real Go caches (resolved outside the sandbox), so modules download only the first time.
  # Never a temp dir: if go cannot report them, stop instead of silently re-downloading everything.
  gocache="$(go env GOCACHE 2>/dev/null || true)"; gomodcache="$(go env GOMODCACHE 2>/dev/null || true)"
  [ -n "$gocache" ] && [ -n "$gomodcache" ] || { echo "錯誤:go env GOCACHE / GOMODCACHE 取不到(go 沒安裝?)" >&2; return 1; }
  echo "PATH=$PATH"
  echo "HOME=$d/home"
  echo "TMPDIR=$d/gotmp"
  echo "GOCACHE=$gocache"
  echo "GOMODCACHE=$gomodcache"
  echo "GOTOOLCHAIN=local"
  echo "GOFLAGS=-mod=readonly"
  echo "PGPASSFILE=/dev/null"
  echo "PGSERVICEFILE=/dev/null"
  # Go download settings: resolved from the user's go env (may come from `go env -w`, which env -i would lose).
  for v in $GO_NET_VARS; do
    val="$(go env "$v" 2>/dev/null || true)"
    [ -n "$val" ] && echo "$v=$val"
  done
  for v in $PROXY_VARS; do
    eval "val=\${$v:-}"
    [ -n "$val" ] && echo "$v=$val"
  done
  return 0
}

# Extra variables explicitly passed by the caller must be DSNs that pass the guard, or plain values that neither
# look like a connection target (host=, @, host:port, other URLs) nor sit under a connection-looking name.
# This is a heuristic backstop: pass only the DSN variables the project's tests read.
check_extra_env() {
  local kv k v
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) die "--env 需要 K=V:$kv" 2 ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ""|*[!A-Za-z0-9_]*) die "環境變數名稱不合法:$k" 2 ;; esac
    local ku; ku="$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')"
    case "$v" in
      postgres://*|postgresql://*) QUIET_GUARD=1 guard_dsns "$v" ;;
      *://*) die "$k 的值是非 postgres 的 URL,拒絕" 4 ;;
      *host=*|*hostaddr=*|*@*|*[A-Za-z0-9.]:[0-9]*|*\[*\]:[0-9]*) die "$k 的值看起來是連線設定(host= / @),拒絕(只接受指向本容器的 postgres:// URL)" 4 ;;
      *)
        case "$ku" in
          PG*|*DATABASE*|*DSN*|*_URL|*_URI|*DB*|*HOST*|*POSTGRES*|*ADDR*|*PORT*|*SERVER*|*SOCKET*) [ -z "$v" ] || die "$k 看起來是連線設定但不是 postgres:// URL,拒絕(只接受指向本容器的 URL)" 4 ;;
        esac ;;
    esac
  done
}

# usage: run_iso <name> [K=V ...] -- cmd args...
run_iso() {
  local name="$1"; shift
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] || die "run_iso 缺少 --" 2
  shift
  [ ${#extra[@]} -eq 0 ] || check_extra_env "${extra[@]}"
  local base=() line
  local envtxt; envtxt="$(iso_base_env "$name")" || die "無法建立隔離環境" 1
  while IFS= read -r line; do base+=("$line"); done <<< "$envtxt"
  env -i "${base[@]}" ${extra[@]+"${extra[@]}"} "$@"
}
