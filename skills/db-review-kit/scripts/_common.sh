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
# The tmp root and <name> dir must be real directories owned by the current user (0700): state.env is sourced and the
# goose binary is executed from there, so a dir planted by another local user (shared /tmp on Linux) is refused.
own_dir() {
  [ ! -L "$1" ] || die "$1 是 symlink,拒絕使用" 4
  local created=""
  if [ ! -e "$1" ]; then mkdir -p "$1" 2>/dev/null && created=1; fi
  [ -d "$1" ] && [ -O "$1" ] || die "$1 不是目前使用者擁有的目錄,拒絕使用(改用 DB_REVIEW_KIT_TMP 指定自己的目錄)" 4
  if [ -n "$created" ]; then chmod 700 "$1"
  elif [ -n "$(find "$1" -maxdepth 0 \( -perm -0020 -o -perm -0002 \) 2>/dev/null)" ]; then
    die "$1 可被群組或其他人寫入,拒絕使用(不會替你改權限;請 chmod go-w 或改用別的目錄)" 4
  fi
}
ensure_name_dir() { own_dir "$KIT_TMP"; own_dir "$KIT_TMP/$1"; }
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
  ensure_name_dir "$1"
  local f; f="$(state_file "$1")"
  [ -f "$f" ] || die "找不到 $1 的容器狀態($f);先 pg.sh up $1" 1
  [ -O "$f" ] && [ ! -L "$f" ] || die "$f 不是目前使用者擁有的一般檔案,拒絕載入" 4
  # shellcheck disable=SC1090
  . "$f"
  case "$CONTAINER" in "dbrev-$1-"*) ;; *) die "狀態檔的容器名稱不符前綴 dbrev-$1-:$CONTAINER" 4 ;; esac
}

# Container must exist, carry label dbrev=<name>, and have the expected prefix.
verify_container() {
  local name="$1" label
  label="$(docker inspect -f '{{ index .Config.Labels "dbrev" }}' "$CONTAINER" 2>/dev/null || true)"
  [ "$label" = "$name" ] || die "容器 $CONTAINER 不存在或 label dbrev 不是 $name" 4
  # the host port must still be the one in state.env (host-side clients — goose, go test — connect through it)
  [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ] || die "容器 $CONTAINER 沒有在執行" 1
  docker port "$CONTAINER" 5432/tcp 2>/dev/null | grep -qx "127.0.0.1:$PORT" || die "容器 $CONTAINER 的埠已不是 127.0.0.1:$PORT(被重建 / 重啟?),先 pg.sh rm 再 up" 4
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
# Note: startup options override ALTER ROLE … SET for these two settings; to observe a role's own timeout,
# put the same value in the DSN options (pg.sh dsn … --options '-c lock_timeout=1s').
# usage: psql_dsn <dsn> [psql args...]   (SQL from stdin unless -c/-f given)
psql_dsn() {
  local dsn="$1"; shift
  QUIET_GUARD=1 guard_dsns "$dsn"
  local idsn
  # standard_conforming_strings is pinned on: _txcheck.py lexes '…' literals with that rule (the guard refuses DSN
  # options and _txcheck refuses SQL that change it)
  idsn="$(dsnpy opts "$dsn" "-c statement_timeout=${ST_OVERRIDE:-$DBREV_STATEMENT_TIMEOUT} -c lock_timeout=${LT_OVERRIDE:-$DBREV_LOCK_TIMEOUT} -c standard_conforming_strings=on")"
  # The password travels as PGPASSWORD in docker exec's environment (taken from this process via `-e PGPASSWORD`),
  # never in argv, so `ps` does not show it; it still works when the bootstrap requires scram on 127.0.0.1.
  local pw; pw="$(dsnpy field "$idsn" password)"
  idsn="$(dsnpy nopass "$(dsnpy internal "$idsn")")"
  # psql exits 3 on a script error with ON_ERROR_STOP; map it to 1 (3 means "Docker not running" in this kit).
  local prc=0
  local redir=""; [ -z "${PSQL_MERGE_STDERR:-}" ] || redir=" 2>&1"
  # docker exec forwards stdout and stderr on separate channels (their relative order is lost); PSQL_MERGE_STDERR
  # merges them inside the container. PGPASSWORD is expanded by the container shell, not placed in host argv.
  PGPASSWORD="$pw" docker exec -i -e PGPASSWORD "$CONTAINER" sh -c \
    'exec env -i PATH=/usr/local/bin:/usr/bin:/bin PGPASSWORD="$PGPASSWORD" PGPASSFILE=/nonexistent/dbrev-pgpass PGSERVICEFILE=/dev/null psql "$@"'"$redir" \
    psql -X -v ON_ERROR_STOP=1 -v VERBOSITY=verbose "$idsn" "$@" || prc=$?
  [ $prc -ne 3 ] || prc=1
  return $prc
}

# ---------- isolated environment for go / goose ----------
# Never inherits DATABASE_URL, TEST_*, PG*, GOOSE_* etc.: everything goes through env -i plus an allowlist.
GO_NET_VARS="GOPROXY GOSUMDB GOPRIVATE GONOSUMDB GONOPROXY GOINSECURE"
PROXY_VARS="HTTPS_PROXY HTTP_PROXY NO_PROXY https_proxy http_proxy no_proxy"

# Prints KEY=VALUE lines of the isolated base environment (one per line).
iso_base_env() {
  local name="$1" d; d="$(name_dir "$name")"
  local tmp="${ISO_TMPDIR:-$d/gotmp}"   # per-run TMPDIR when the caller sets ISO_TMPDIR (parallel runs on one <name>)
  mkdir -p "$d/home" "$tmp"
  local gocache gomodcache v val
  # The user's real Go caches (resolved outside the sandbox), so modules download only the first time.
  # Never a temp dir: if go cannot report them, stop instead of silently re-downloading everything.
  gocache="$(go env GOCACHE 2>/dev/null || true)"; gomodcache="$(go env GOMODCACHE 2>/dev/null || true)"
  [ -n "$gocache" ] && [ -n "$gomodcache" ] || { echo "錯誤:go env GOCACHE / GOMODCACHE 取不到(go 沒安裝?)" >&2; return 1; }
  echo "PATH=$PATH"
  echo "HOME=$d/home"
  echo "TMPDIR=$tmp"
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
  local kv k v ku tok looks
  for kv in "$@"; do
    case "$kv" in *=*) ;; *) die "--env 需要 K=V:$kv" 2 ;; esac
    k="${kv%%=*}"; v="${kv#*=}"
    case "$k" in ""|*[!A-Za-z0-9_]*) die "環境變數名稱不合法:$k" 2 ;; esac
    ku="$(printf '%s' "$k" | tr '[:lower:]' '[:upper:]')"
    # The sandbox's own settings cannot be overridden (GOFLAGS=-mod=readonly, GOTOOLCHAIN=local, HOME, caches …).
    case "$ku" in
      PATH|HOME|TMPDIR|PGPASSFILE|PGSERVICEFILE|GOFLAGS|GOTOOLCHAIN|GOROOT|GOPATH|GOBIN|GOENV|GOAUTH|GOPROXY|GOSUMDB|GOPRIVATE|GONOSUMDB|GONOPROXY|GOINSECURE|GOCACHE|GOMODCACHE|GOWORK|GOTMPDIR|GOVCS|GOEXPERIMENT|GODEBUG|GOOS|GOARCH|GOAMD64|GOARM|GOARM64|GO386|GOMIPS|GOMIPS64|GOPPC64|GORISCV64|GOWASM|GOTELEMETRY|GOTELEMETRYDIR|GOCOVERDIR|GOGC|GOMAXPROCS|GOMEMLIMIT|GOTRACEBACK|GOFIPS140|GCCGO|GCCGOTOOLDIR|CGO_*|CC|CXX|AR|FC|PKG_CONFIG*|GIT_*|SSH_*|LD_*|DYLD_*|BASH_ENV|ENV|SHELL|IFS|PS4|PROMPT_COMMAND)
        die "$k 是隔離環境 / 工具鏈會執行的變數,不能用 --env 覆寫" 4 ;;
    esac
    case "$v" in
      postgres://*|postgresql://*) QUIET_GUARD=1 guard_dsns "$v"; continue ;;
      *://*) die "$k 的值是非 postgres 的 URL,拒絕" 4 ;;
    esac
    if printf '%s' "$v" | grep -Eq ':[^[:space:]@/]*@[A-Za-z0-9.-]+'; then
      die "$k 的值看起來是 帳號:密碼@主機,拒絕(只接受指向本容器的 postgres:// URL)" 4
    fi
    if printf '%s' "$v" | grep -Eqi '(^|[[:space:]])(host|hostaddr|dbname|user|port|service|sslmode|password)[[:space:]]*='; then
      die "$k 的值看起來是 libpq 連線字串,拒絕" 4
    fi
    if printf '%s' "$v" | grep -Eq '^([A-Za-z][A-Za-z0-9.-]*|[0-9]+(\.[0-9]+){3}|\[[0-9A-Fa-f:]+\]):[0-9]{2,5}$'; then
      die "$k 的值看起來是 主機:埠,拒絕" 4
    fi
    # Connection-looking names (whole _-separated tokens, so REPORT_DIR / FEEDBACK are fine) must carry a guarded URL.
    looks=""
    for tok in $(printf '%s' "$ku" | tr '_' ' '); do
      case "$tok" in
        PG*|DATABASE|DSN|DB|HOST|POSTGRES|POSTGRESQL|ADDR|PORT|SERVER|SOCKET|URL|URI|CONN|CONNECTION|INSTANCE|ENDPOINT|DATASOURCE|CLOUDSQL) looks=1 ;;
      esac
    done
    [ -z "$looks" ] || [ -z "$v" ] || die "$k 看起來是連線設定但不是 postgres:// URL,拒絕(只接受指向本容器的 URL)" 4
  done
}

# usage: run_iso <name> [K=V ...] -- cmd args...   (K=V from users must pass check_extra_env first)
run_iso() {
  local name="$1"; shift
  local extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra+=("$1"); shift; done
  [ "${1:-}" = "--" ] || die "run_iso 缺少 --" 2
  shift
  # Caller-supplied variables are validated by check_extra_env before this (gotest.sh); kit-internal ones (GOBIN) are trusted.
  local base=() line
  local envtxt; envtxt="$(iso_base_env "$name")" || die "無法建立隔離環境" 1
  while IFS= read -r line; do base+=("$line"); done <<< "$envtxt"
  env -i "${base[@]}" ${extra[@]+"${extra[@]}"} "$@"
}
