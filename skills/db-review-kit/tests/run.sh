#!/bin/bash
# db-review-kit self-test. Offline except: Docker (local) for the container tests, and Go module downloads for the
# fixture / goose CLI on the first run. Image: postgres:18-alpine (pulled if missing, removed afterwards only if this
# test pulled it). Items that cannot run (no docker / no go) print SKIP, which does not count as passing.
# Everything is cleaned up: containers labelled dbrev=<test name>, tmp dirs, background processes.
set -uo pipefail
KIT="$(cd "$(dirname "$0")/.." && pwd)"
S="$KIT/scripts"; FX="$KIT/tests/fixture"
IMAGE="${DB_REVIEW_KIT_TEST_IMAGE:-postgres:18-alpine}"
WORK="$(mktemp -d)"
export DB_REVIEW_KIT_TMP="$WORK/kit"
N="kst-$$"
PASS=0; FAIL=0; SKIP=0
ok()   { echo "PASS  $1"; PASS=$((PASS + 1)); }
bad()  { echo "FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -20 | sed 's/^/      /'; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP  $1"; SKIP=$((SKIP + 1)); }
PULLED=""
cleanup() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    for c in $(docker ps -a --filter "label=dbrev=$N" --format '{{.Names}}') $(docker ps -a --filter "label=dbrev=$N-old" --format '{{.Names}}') $(docker ps -a --filter "label=dbrev=$N-scram" --format '{{.Names}}'); do docker rm -f -v "$c" >/dev/null 2>&1; done
    [ -n "$PULLED" ] && docker image rm "$IMAGE" >/dev/null 2>&1
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT
DSNPY() { python3 -I "$S/_dsn.py" "$@"; }

# ---------- 1. DSN guard (offline) ----------
o="$(DSNPY guard 6000 'postgres://u:p@127.0.0.1:6000/db?sslmode=disable')"; [ $? -eq 0 ] && echo "$o" | grep -q 'guard ok #1 host=127.0.0.1 port=6000 user=u db=db' && ok "guard:本容器 DSN 通過" || bad "guard ok" "$o"
for d in 'postgres://u:p@10.0.0.5:6000/db' 'postgres://u:p@localhost:6000/db' 'postgres://u:p@127.0.0.1:5432/db' \
         'postgres://u:p@127.0.0.1:6000/db?host=10.0.0.5' 'postgres://u:p@127.0.0.1:6000/db?hostaddr=10.0.0.5' \
         'postgres://u:p@127.0.0.1:6000/db?service=prod' 'postgres://u:p@127.0.0.1:6000,10.0.0.5:6000/db' \
         'mysql://u:p@127.0.0.1:6000/db' 'postgres://u:p@127.0.0.1:6000/' 'postgres://u:p@127.0.0.1:6000/db?passfile=/x'; do
  o="$(DSNPY guard 6000 "$d")"; rc=$?
  [ $rc -eq 4 ] && echo "$o" | grep -q 'guard FAIL' && ! echo "$o" | grep -q ':p@' && ok "guard:拒絕 $d" || bad "guard 應拒絕 $d" "rc=$rc $o"
done
o="$(DSNPY opts 'postgres://u:p@127.0.0.1:6000/db?options=-c%20lock_timeout%3D9s' '-c lock_timeout=5s -c statement_timeout=60s')"
[ "$o" = 'postgres://u:p@127.0.0.1:6000/db?options=-c%20lock_timeout%3D5s%20-c%20statement_timeout%3D60s%20-c%20lock_timeout%3D9s' ] \
  && ok "opts:kit 預設在前,DSN 自己的 options 在後(後者生效)" || bad "opts 合併" "$o"
[ "$(DSNPY internal 'postgres://u:p@127.0.0.1:6000/db?x=1')" = 'postgres://u:p@127.0.0.1:5432/db?x=1' ] && ok "internal:改寫成容器內 127.0.0.1:5432" || bad "internal"
[ "$(DSNPY mask 'postgres://u:secret@127.0.0.1:6000/db')" = 'postgres://u:***@127.0.0.1:6000/db' ] && ok "mask:隱藏密碼" || bad "mask"
[ "$(DSNPY mask 'postgres://u@127.0.0.1:6000/db?password=secret&sslmode=disable')" = 'postgres://u@127.0.0.1:6000/db?password=***&sslmode=disable' ] && ok "mask:也隱藏 ?password=" || bad "mask password param" "$(DSNPY mask 'postgres://u@127.0.0.1:6000/db?password=secret&sslmode=disable')"

# ---------- 2. isolated env (offline) ----------
o="$(DATABASE_URL=postgres://evil@10.255.255.1/x PGHOST=10.255.255.1 PGPASSWORD=leak TEST_DATABASE_URL=postgres://x@10.0.0.1/y_test GOOSE_DBSTRING=x GOFLAGS=-mod=mod \
     bash -c "source '$S/_common.sh'; run_iso $N -- env" 2>&1)"
if ! echo "$o" | grep -qE '^(DATABASE_URL|PGHOST|PGPASSWORD|TEST_DATABASE_URL|GOOSE_DBSTRING)=' && echo "$o" | grep -qx 'GOFLAGS=-mod=readonly' \
   && echo "$o" | grep -qx 'PGPASSFILE=/dev/null' && echo "$o" | grep -qx 'GOTOOLCHAIN=local' && echo "$o" | grep -q "^HOME=$DB_REVIEW_KIT_TMP/$N/home"; then
  ok "隔離:shell 的 DATABASE_URL / PG* / TEST_* / GOOSE_* 不會被繼承;GOFLAGS=-mod=readonly、GOTOOLCHAIN=local、HOME 在暫存目錄"
else bad "隔離環境" "$o"; fi
if command -v go >/dev/null 2>&1; then
  real_mod="$(go env GOMODCACHE)"; real_cache="$(go env GOCACHE)"
  if echo "$o" | grep -qx "GOMODCACHE=$real_mod" && echo "$o" | grep -qx "GOCACHE=$real_cache" && [ -n "$real_mod" ] \
     && ! echo "$o" | grep -E '^GO(MOD)?CACHE=' | grep -q "$WORK"; then
    ok "隔離:沙盒用使用者真正的 GOMODCACHE($real_mod)與 GOCACHE,不是暫存目錄"
  else bad "沙盒 GOMODCACHE / GOCACHE" "$(echo "$o" | grep -E '^GO(MOD)?CACHE=') real=$real_mod $real_cache"; fi
else skip "沙盒 GOMODCACHE(沒有 go)"; fi
o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env 'DATABASE_URL=host=10.0.0.1 dbname=x'" 2>&1)"; rc=$?
[ $rc -eq 4 ] && ok "隔離:DB 類變數不是 URL(keyword DSN)→ 拒絕(結束碼 4)" || bad "keyword DSN 應拒絕" "rc=$rc $o"
mkdir -p "$WORK/gw"; chmod 0775 "$WORK/gw"
o="$(DB_REVIEW_KIT_TMP="$WORK/gw" bash -c "source '$S/_common.sh' && ensure_name_dir x" 2>&1)"; rc=$?
[ $rc -eq 4 ] && echo "$o" | grep -q '可被群組或其他人寫入' && ok "暫存目錄:既有目錄群組可寫(0775)→ 拒絕,不改權限" || bad "暫存目錄 0775" "rc=$rc $o"
o="$(DB_REVIEW_KIT_TMP="$WORK/foreign" bash -c "mkdir -p '$WORK/real' && ln -s '$WORK/real' '$WORK/foreign' && source '$S/_common.sh' && ensure_name_dir x" 2>&1)"; rc=$?
[ $rc -eq 4 ] && echo "$o" | grep -q 'symlink' && ok "暫存目錄:根目錄是 symlink → 拒絕(結束碼 4)" || bad "暫存目錄 symlink" "rc=$rc $o"
for kv in 'XDG_CONFIG_HOME=/tmp/x' 'GOCACHEPROG=sh -c id' 'GOAUTH=sh -c id' 'CC=/tmp/evil' 'GIT_SSH_COMMAND=sh -c id' 'DYLD_INSERT_LIBRARIES=/tmp/x.dylib' 'LD_PRELOAD=/tmp/x.so'; do
  o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env '$kv'" 2>&1)"; [ $? -eq 4 ] && ok "隔離:${kv%%=*} 等會被工具鏈執行的變數不能傳" || bad "${kv%%=*} 應拒絕" "$o"
done
o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env 'GORM_LOG=silent'" 2>&1)"; [ $? -eq 0 ] && ok "隔離:GORM_* 這類非工具鏈的 GO 開頭變數可以傳" || bad "GORM 誤擋" "$o"
o="$(DSNPY guard 6000 'postgres://u:p@127.0.0.1:6000/db?options=-c%20standard_conforming_strings%3Doff')"; [ $? -eq 4 ] && ok "guard:DSN options 改 standard_conforming_strings → 拒絕" || bad "guard scs" "$o"
o="$(DSNPY guard 6000 'postgres://u:p@127.0.0.1:6000/db?options=--standard-conforming-strings%3Doff')"; [ $? -eq 4 ] && ok "guard:連字號寫法 --standard-conforming-strings 也拒絕" || bad "guard scs dash" "$o"
o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env 'GOOSE_TABLE=fx_meta.goose_db_version'" 2>&1)"; [ $? -eq 0 ] && ok "隔離:GOOSE_TABLE 這類專案變數可以傳" || bad "GOOSE_TABLE 誤擋" "$o"
o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env 'TEST_ARGS=--report=json' 'NOTIFY=ci@example.com' 'SUPER=superuser=on'" 2>&1)"; [ $? -eq 0 ] && ok "隔離:--report=json、email 這類值不誤擋" || bad "誤擋 report/email" "$o"
for kv in 'TARGET=app@staging-db.internal:5432' 'FX_TARGET=localhost:5432/devdb' 'GOTOOLDIR=/x' 'TEST_PGHOST=staging-db.internal' 'CLOUDSQL_INSTANCE=proj:region:inst' 'X=app:secret@db.internal/prod' 'APP_TARGET=host = 10.0.0.5 dbname = prod' 'GOFLAGS=-mod=mod' 'GOTOOLCHAIN=auto' 'HOME=/tmp' 'APP_CONN=dbname=lobby user=app sslmode=disable' 'test_db=host=10.0.0.5 port=5432 dbname=prod' 'DB_HOST=10.0.0.5' 'TEST_POSTGRES_ADDR=10.0.0.5:5432' 'OTHER=db.internal:5432' 'APP_TARGET=u:p@10.0.0.5/db' 'X=mysql://u@10.0.0.5/db'; do
  o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env '$kv'" 2>&1)"; rc=$?
  [ $rc -eq 4 ] && ok "隔離:--env $kv → 拒絕" || bad "--env $kv 應拒絕" "rc=$rc $o"
done
o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env 'REPORT_DIR=/tmp/out' 'TEST_FEEDBACK_MODE=on' 'START_AT=12:30'" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "隔離:REPORT_DIR / FEEDBACK / 12:30 這類無關變數不誤擋" || bad "誤擋無關變數" "rc=$rc $o"
o="$(bash -c "source '$S/_common.sh'; PORT=6000; check_extra_env 'TEST_DATABASE_URL=postgres://u:p@127.0.0.1:5432/x_test'" 2>&1)"; rc=$?
[ $rc -eq 4 ] && ok "隔離:--env 的 DSN 指向別的埠 → 拒絕" || bad "--env 錯埠應拒絕" "rc=$rc $o"

# ---------- 3. gotest parser (offline) ----------
printf '%s\n' '{"Action":"start","Package":"p"}' '{"Action":"output","Package":"p","Output":"ok  \tp\t0.1s [no tests to run]\n"}' '{"Action":"pass","Package":"p"}' > "$WORK/zero.jsonl"
o="$(python3 -I "$S/_gotest_parse.py" "$WORK/zero.jsonl" 1)"
echo "$o" | grep -q '"status": "GAP"' && echo "$o" | grep -q 'no tests ran' && ok "gotest 解析:測試數 0 → GAP" || bad "測試數 0" "$o"
printf '%s\n' '{"ImportPath":"p [p.test]","Action":"build-output","Output":"x.go:1: undefined: y\n"}' '{"ImportPath":"p [p.test]","Action":"build-fail"}' \
  '{"Action":"start","Package":"p"}' '{"Action":"output","Package":"p","Output":"FAIL\tp [build failed]\n"}' '{"Action":"fail","Package":"p"}' > "$WORK/bf.jsonl"
o="$(python3 -I "$S/_gotest_parse.py" "$WORK/bf.jsonl" 1)"
echo "$o" | grep -q '"status": "FAIL"' && echo "$o" | grep -q '"packages": {"ok": 0, "fail": 0, "no_tests": 0, "build_fail": 1}' && ok "gotest 解析:編譯失敗 → FAIL(同一個套件只算一次 build_fail)" || bad "編譯失敗" "$o"

printf '%s\n' 'go: updates to go.mod needed; to update it:' '	go mod tidy' > "$WORK/plain.jsonl"
o="$(python3 -I "$S/_gotest_parse.py" "$WORK/plain.jsonl" 1 1)"
echo "$o" | grep -q '"status": "FAIL"' && echo "$o" | grep -q 'go mod tidy' && ok "gotest 解析:go 結束碼非 0 但沒有測試事件 → FAIL(不是 GAP)" || bad "go rc 非 0" "$o"

# ---------- 4. non-local docker refused (offline) ----------
for h in tcp://192.0.2.1:2375 ssh://user@192.0.2.1; do
  o="$(DOCKER_HOST="$h" bash "$S/pg.sh" up "$N" --image "$IMAGE" 2>&1)"; rc=$?
  [ $rc -eq 4 ] && echo "$o" | grep -q '不是本機' && ok "非本機 docker:DOCKER_HOST=$h → 結束碼 4" || bad "DOCKER_HOST=$h 應拒絕" "rc=$rc $o"
done
if command -v docker >/dev/null 2>&1; then
  export_cfg="$WORK/dockercfg"; mkdir -p "$export_cfg"
  if DOCKER_CONFIG="$export_cfg" docker context create dbrev-remote --docker host=tcp://192.0.2.1:2375 >/dev/null 2>&1; then
    o="$(env -u DOCKER_HOST DOCKER_CONFIG="$export_cfg" DOCKER_CONTEXT=dbrev-remote bash "$S/pg.sh" up "$N" --image "$IMAGE" 2>&1)"; rc=$?
    [ $rc -eq 4 ] && echo "$o" | grep -q 'dbrev-remote' && ok "非本機 docker:context 指向 tcp:// → 結束碼 4" || bad "遠端 context 應拒絕" "rc=$rc $o"
  else skip "非本機 docker context(docker context create 失敗)"; fi
else skip "非本機 docker context(沒有 docker CLI)"; fi
o="$(bash "$S/pg.sh" up "$N" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q -- '--image 必填' && ok "pg.sh up:沒給 --image → 用法錯誤(不提供預設映像)" || bad "--image 必填" "$o"

# ---------- docker section ----------
if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  for t in "pg.sh up / psql / guard / rm / gc" "goose.sh" "locks.sh" "grants.sh" "race.sh" "seed.sh / explain.sh" "partitions.sql" "gotest.sh"; do skip "$t(Docker 沒有在執行)"; done
  echo "---"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; [ "$FAIL" -eq 0 ]; exit
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  docker pull -q "$IMAGE" >/dev/null && PULLED=1 || { bad "docker pull $IMAGE"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; exit 1; }
fi
GIT_BEFORE="$(git -C "$FX" status --porcelain -- . 2>/dev/null || echo no-git)"
SKIPTOK="$WORK/skip-txcheck.token"; echo dbrev-selftest-skip-txcheck > "$SKIPTOK"
VOL_BEFORE="$(docker volume ls -q --filter label=com.docker.volume.anonymous | sort)"

o="$(bash "$S/pg.sh" up "$N" --image "$IMAGE" --mount "$FX/db/init:/docker-entrypoint-initdb.d" --mount "$FX/db/roles.sql:/roles.sql:rw" 2>&1)"; rc=$?
[ $rc -eq 4 ] && echo "$o" | grep -q '一律唯讀' && ok "pg.sh up:--mount 帶 :rw → 拒絕(結束碼 4)" || bad "--mount rw 應拒絕" "rc=$rc $o"
o="$(bash "$S/pg.sh" up "$N" --image "$IMAGE" --env "APP_PW=a b" --role app=APP_PW 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$o" | grep -q '只能是英數' && [ -z "$(docker ps -aq --filter "label=dbrev=$N")" ] && ok "pg.sh up:--role 密碼含空白 → 拒絕並刪容器" || bad "role 密碼檢查" "rc=$rc $o"
o="$(bash "$S/pg.sh" up "$N" --image "$IMAGE" --mount "$FX/db/init:/docker-entrypoint-initdb.d" --env-random FX_MIGRATOR_PASSWORD FX_APP_PASSWORD 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | grep -q '初始化失敗' && [ -z "$(docker ps -aq --filter "label=dbrev=$N")" ] \
  && ok "pg.sh up:init 腳本要的 /roles.sql 沒掛載 → 初始化失敗並刪掉容器" || bad "init 失敗處理" "rc=$rc $o"

UP="$(bash "$S/pg.sh" up "$N" --image "$IMAGE" --tmpfs-size 768m \
  --mount "$FX/db/init:/docker-entrypoint-initdb.d" --mount "$FX/db/roles.sql:/roles.sql:ro" \
  --env-random FX_MIGRATOR_PASSWORD FX_APP_PASSWORD --role fx_migrator=FX_MIGRATOR_PASSWORD --role fx_app=FX_APP_PASSWORD --db fx_test 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then bad "pg.sh up(fixture bootstrap)" "$UP"; echo "pass=$PASS fail=$FAIL skip=$SKIP"; exit 1; fi
C="$(echo "$UP" | sed -n 's/^container=\([^ ]*\) .*/\1/p')"; PORT="$(echo "$UP" | sed -n 's/^container=[^ ]* port=\([0-9]*\).*/\1/p')"
case "$C" in "dbrev-$N-"*) ok "pg.sh up:容器名稱前綴 dbrev-$N-" ;; *) bad "容器名稱" "$C" ;; esac
[ "$(docker inspect -f '{{index .Config.Labels "dbrev"}}' "$C")" = "$N" ] && ok "pg.sh up:label dbrev=$N" || bad "label"
[ "$(docker inspect -f '{{.HostConfig.ShmSize}}' "$C")" = 268435456 ] && ok "pg.sh up:--shm-size 256m(平行查詢用的共享記憶體)" || bad "shm-size" "$(docker inspect -f '{{.HostConfig.ShmSize}}' "$C")"
[ "$(docker inspect -f '{{index .HostConfig.Tmpfs "/var/lib/postgresql"}}' "$C")" = "rw,size=768m" ] && ok "pg.sh up:tmpfs /var/lib/postgresql size=768m" || bad "tmpfs" "$(docker inspect -f '{{json .HostConfig.Tmpfs}}' "$C")"
m="$(docker inspect -f '{{range .Mounts}}{{.Type}}:{{.Destination}}:{{.RW}} {{end}}' "$C")"
[ "$m" = "bind:/docker-entrypoint-initdb.d:false bind:/roles.sql:false " ] || [ "$m" = "bind:/roles.sql:false bind:/docker-entrypoint-initdb.d:false " ] \
  && ok "pg.sh up:只有兩個唯讀 bind mount,沒有資料 volume" || bad "mounts" "$m"
[ "$(docker port "$C" 5432/tcp)" = "127.0.0.1:$PORT" ] && ok "pg.sh up:只綁 127.0.0.1:$PORT" || bad "port binding" "$(docker port "$C")"
echo "$UP" | grep -q "^dsn role=fx_app db=fx_test url=postgres://fx_app:[0-9a-f]\{32\}@127.0.0.1:$PORT/fx_test" && ok "pg.sh up:印出各角色 DSN(隨機密碼)" || bad "DSN 輸出" "$UP"
SU="$(bash "$S/pg.sh" dsn "$N" postgres fx_test)"; MIG="$(bash "$S/pg.sh" dsn "$N" fx_migrator fx_test)"; APP="$(bash "$S/pg.sh" dsn "$N" fx_app fx_test)"
MIGA="$(bash "$S/pg.sh" dsn "$N" fx_migrator fx_test --options '-c fx.allow_data_down=on')"
o="$(echo "SELECT string_agg(nspname, ',' ORDER BY nspname) FROM pg_namespace WHERE nspname LIKE 'fx%';" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
[ "$o" = "fx,fx_meta" ] && ok "pg.sh up:init 腳本讀到另外掛載的 /roles.sql(schema fx、fx_meta 已建立)" || bad "roles.sql" "$o"
o="$(bash "$S/pg.sh" up "$N" --image "$IMAGE" 2>&1)"; [ $? -eq 1 ] && echo "$o" | grep -q 'pg.sh gc' && ok "pg.sh up:同名容器已存在 → 拒絕" || bad "同名拒絕" "$o"

o="$(echo "SELECT current_setting('statement_timeout') || ' ' || current_setting('lock_timeout');" | bash "$S/pg.sh" psql "$N" "$APP" -At 2>&1)"
[ "$o" = "1min 5s" ] && ok "psql:每個 session 預設 statement_timeout 60s、lock_timeout 5s" || bad "psql 預設 timeout" "$o"
o="$(echo "SELECT current_setting('lock_timeout');" | bash "$S/pg.sh" psql "$N" "$(bash "$S/pg.sh" dsn "$N" fx_app fx_test --options '-c lock_timeout=250ms')" -At 2>&1)"
[ "$o" = "250ms" ] && ok "psql:DSN 自己的 options 覆寫 kit 預設" || bad "options 覆寫" "$o"
o="$(echo "SELECT 1;" | bash "$S/pg.sh" psql "$N" "postgres://postgres:x@127.0.0.1:5432/fx_test" -At 2>&1)"; rc=$?
[ $rc -eq 4 ] && ok "psql:DSN 不是本容器的埠 → 拒絕(結束碼 4)" || bad "psql guard" "rc=$rc $o"
o="$(bash "$S/pg.sh" guard "$N" "$APP" "${APP}&host=db.internal" 2>&1)"; rc=$?
[ $rc -eq 4 ] && echo "$o" | grep -q 'guard ok #1' && echo "$o" | grep -q 'guard FAIL #2' && ok "pg.sh guard:逐一回報,有一個不符就結束碼 4" || bad "pg.sh guard" "rc=$rc $o"

# ---------- goose ----------
if ! command -v go >/dev/null 2>&1; then skip "goose.sh(沒有 go)"; skip "gotest.sh(沒有 go)"; else
o="$(bash "$S/goose.sh" "$N" validate --dir "$FX/migrations" 2>&1)"; [ $? -eq 0 ] && ok "goose.sh validate(版本取自 go.mod:$(echo "$o" | sed -n 's/^goose=\([^ ]*\).*/\1/p'))" || bad "goose validate" "$o"
o="$(DATABASE_URL=postgres://evil@10.255.255.1/x GOOSE_DBSTRING=postgres://evil@10.255.255.1/x bash "$S/goose.sh" "$N" roundtrip --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" --dsn-allow "$MIGA" --from 3 2>&1)"; rc=$?
j="$(echo "$o" | tail -1)"
echo "$j" | grep -q '"before": 2' && echo "$j" | grep -q '"down_no_flag": "rejected"' && echo "$j" | grep -q '"down_with_flag": "ok"' \
  && echo "$j" | grep -q '"up_again": "ok"' && echo "$j" | grep -q '"ok": true' && echo "$j" | grep -q '"down_rejected_without_flag": true' && echo "$j" | grep -q 'fx.allow_data_down' && [ $rc -eq 0 ] \
  && ok "goose.sh roundtrip:前一版 → up → down 不帶旗標被拒(RAISE)→ 帶旗標成功 → up" || bad "goose roundtrip" "$o"
o="$(bash "$S/goose.sh" "$N" roundtrip --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" --from 3 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | grep -q 'up 不會真的執行' && ok "goose.sh roundtrip:資料庫已在審查版本、沒給 --dsn-allow → 拒絕(不會假裝 up 過)" || bad "roundtrip 已在版本" "rc=$rc $o"
o="$(bash "$S/goose.sh" "$N" roundtrip --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" --dsn-allow "$MIGA" --from 3 2>&1)"; rc=$?
echo "$o" | grep -q '== 0 down-to before first' && echo "$o" | tail -1 | grep -q '"ok": true' && [ $rc -eq 0 ] && ok "goose.sh roundtrip:已在審查版本時先用 allow DSN 退回再真的 up" || bad "roundtrip 先退回" "rc=$rc $o"
bash "$S/goose.sh" "$N" run --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIGA" -- down-to 2 >/dev/null 2>&1
o="$(bash "$S/goose.sh" "$N" roundtrip --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" --from 3 2>&1)"; rc=$?
echo "$o" | tail -1 | grep -q '"down_with_flag": "no-allow-dsn"' && [ $rc -eq 1 ] && ok "goose.sh roundtrip:沒給 --dsn-allow 時破壞性 Down 無法完成 → ok=false" || bad "roundtrip 無 allow" "$o"
o="$(bash "$S/goose.sh" "$N" run --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "postgres://fx_migrator:x@127.0.0.1:5432/fx_test" -- status 2>&1)"; rc=$?
[ $rc -eq 4 ] && ok "goose.sh:DSN 不是本容器 → 拒絕" || bad "goose guard" "rc=$rc $o"
o="$(bash "$S/goose.sh" "$N" roundtrip --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" --dsn-allow "$MIGA" --from 2 --to 2 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | grep -q '高於 --to 2' && ok "goose.sh roundtrip:資料庫版本高於 --to → 拒絕(不連帶 down 範圍外的 migration)" || bad "roundtrip 版本檢查" "rc=$rc $o"
o="$(bash "$S/goose.sh" "$N" run --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIGA" -- down-to 2 2>&1)" \
  && ok "goose.sh run:down-to 2(準備觀察 00003 的鎖)" || bad "goose run down-to" "$o"

# ---------- locks ----------
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --goose-up "$FX/migrations/00003_notes.sql" 2>&1)"; rc=$?
gone="$(echo "SELECT to_regclass('fx.notes') IS NULL;" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
echo "$o" | grep -q '| fx.accounts | ShareRowExclusiveLock | writes' && echo "$o" | grep -q '| fx.notes (new in this transaction) | AccessExclusiveLock' && echo "$o" | tail -1 | grep -q '"access_exclusive":0' && echo "$o" | tail -1 | grep -q '"rolled_back":true' && [ "$gone" = t ] && [ $rc -eq 0 ] \
  && ok "locks.sh:00003 Up 在交易內觀察到 accounts 的 ShareRowExclusiveLock(擋寫入),結束後已 ROLLBACK" || bad "locks 交易內" "rc=$rc gone=$gone $o"
printf -- '-- +goose Up\nDROP TABLE IF EXISTS fx.no_such_table;\nCREATE INDEX IF NOT EXISTS accounts_pkey ON fx.accounts (id);\n' > "$WORK/notice.sql"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --goose-up "$WORK/notice.sql" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ! echo "$o" | grep -q 'NOTICE' && echo "$o" | tail -1 | grep -q '"ok":true' && ok "locks.sh:DDL 的 NOTICE 不會被當成鎖" || bad "locks NOTICE" "rc=$rc $o"
printf '%s\n' "CREATE FUNCTION fx.tmp_f() RETURNS trigger LANGUAGE plpgsql AS \$\$" "BEGIN" "  IF NEW.balance < 0 THEN RAISE EXCEPTION 'neg'; END IF;" "  RETURN CASE WHEN true THEN NEW END;" "END;" "\$\$;" > "$WORK/fn.sql"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --file "$WORK/fn.sql" 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$o" | tail -1 | grep -q '"ok":true' && ok "locks.sh:plpgsql 函式裡的 BEGIN / END / CASE … END 不算交易控制" || bad "locks 函式本體" "rc=$rc $o"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql 'CREATE FUNCTION fx.tmp_g(x int) RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT CASE WHEN x > 0 THEN 1 ELSE 0 END; END' 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "locks.sh:BEGIN ATOMIC … END 函式本體不算交易控制" || bad "locks BEGIN ATOMIC" "rc=$rc $o"
for q in "SELECT set_config('standard_'||'conforming_strings','off',false); CREATE TABLE fx.tmp_s (i int); SELECT 'x\\'; SELECT '; COMMIT; --'" 'CREATE TABLE fx.tmp_t2 ("case" int); CREATE FUNCTION fx.tmp_f2() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT (t.case) FROM fx.tmp_t2 t; END; COMMIT;' "SET standard_conforming_strings = off; SELECT 'a\\' , ' ; COMMIT ; SELECT ';" 'CREATE TABLE fx.tmp_h (i int); SELECT begin atomic FROM (SELECT 1 AS begin) s; COMMIT; SELECT 1 AS end' 'CREATE TABLE fx.tmp_a (i int); ABORT; CREATE TABLE fx.tmp_b (i int)' 'CREATE TABLE fx.tmp_d (i int);
\c fx_test' 'CREATE TABLE fx.tmp_e (i int) \g
COMMIT' "SELECT E'a\\'b'; COMMIT;"; do
  o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "$q" 2>&1)"; rc=$?
  left="$(echo "SELECT count(*) FROM pg_class WHERE relname LIKE 'tmp_%' AND relnamespace = 'fx'::regnamespace;" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
  [ $rc -eq 2 ] && [ "$left" = 0 ] && ok "locks.sh:交易控制 / psql 指令 → 拒絕(沒有留下物件)" || bad "locks 交易控制" "rc=$rc left=$left $o"
done
# the txid check itself (pre-filter switched off for this case only): a COMMIT inside the SQL is detected
o="$(DBREV_SELFTEST_SKIP_TXCHECK="$SKIPTOK" bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "CREATE TABLE fx.tmp_det (i int); COMMIT; SELECT 1" 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | tail -1 | grep -q '"rolled_back":false' && ok "locks.sh:SQL 中途 COMMIT 會被 txid 檢查偵測(rolled_back:false、結束碼 1)" || bad "locks txid 偵測" "rc=$rc $o"
echo "DROP TABLE IF EXISTS fx.tmp_det;" | bash "$S/pg.sh" psql "$N" "$SU" -q >/dev/null 2>&1
o="$(DBREV_SELFTEST_SKIP_TXCHECK="$SKIPTOK" bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "CREATE TABLE fx.tmp_det (i int); COMMIT; SELECT 1/0" 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | tail -1 | grep -q '"rolled_back":false' && ok "locks.sh:COMMIT 之後又出錯也偵測得到(rolled_back:false)" || bad "locks commit+error" "rc=$rc $o"
echo "DROP TABLE IF EXISTS fx.tmp_det;" | bash "$S/pg.sh" psql "$N" "$SU" -q >/dev/null 2>&1
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "CREATE TABLE fx.tmp_err (i int); SELECT 1/0" 2>&1)"; rc=$?
gone3="$(echo "SELECT to_regclass('fx.tmp_err') IS NULL;" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
[ $rc -eq 1 ] && echo "$o" | tail -1 | grep -q '"rolled_back":true' && [ "$gone3" = t ] && ok "locks.sh:SQL 出錯時回報錯誤且證明已 ROLLBACK" || bad "locks error rollback" "rc=$rc gone=$gone3 $o"
echo "DROP TABLE IF EXISTS fx.tmp_det;" | bash "$S/pg.sh" psql "$N" "$SU" -q >/dev/null 2>&1
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql 'CREATE TABLE fx.tmp_c (i int); COMMIT;' 2>&1)"; rc=$?
gone2="$(echo "SELECT to_regclass('fx.tmp_c') IS NULL;" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
[ $rc -eq 2 ] && [ "$gone2" = t ] && ok "locks.sh:SQL 含 COMMIT → 拒絕,沒有留下物件" || bad "locks COMMIT" "rc=$rc gone=$gone2 $o"
printf -- '-- +goose NO TRANSACTION\n-- +goose Up\nCREATE INDEX CONCURRENTLY IF NOT EXISTS x ON fx.accounts (name);\n' > "$WORK/nt.sql"
o="$(bash "$S/locks.sh" "$N" --dsn "$(echo "$MIG" | sed 's#/fx_test?#/fx_nope?#')" --sql 'SELECT 1' 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | tail -1 | grep -q '"rolled_back":null' && ! echo "$o" | grep -q '重建' && ok "locks.sh:連不上資料庫 → 回報連線錯誤,不會誤報 COMMIT" || bad "locks 連線失敗" "rc=$rc $o"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql 'ALTER TABLE fx.accounts ADD COLUMN x int' 2>&1)"; rc=$?
echo "$o" | grep -q '| fx.accounts | AccessExclusiveLock | reads+writes' && echo "$o" | tail -1 | grep -q '"access_exclusive":1' && [ $rc -eq 0 ] \
  && ok "locks.sh:ALTER 既有表不會被標成 new,ACCESS EXCLUSIVE 有算到" || bad "locks 既有表" "rc=$rc $o"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --goose-up "$WORK/nt.sql" 2>&1)"; [ $? -eq 1 ] && echo "$o" | grep -q 'NO TRANSACTION' && ok "locks.sh:NO TRANSACTION 檔 → 拒絕交易內觀察" || bad "NO TRANSACTION" "$o"
bash "$S/goose.sh" "$N" run --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" -- up >/dev/null 2>&1 || bad "goose up 回到最新版"
START=$(date +%s)
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql 'ALTER TABLE fx.notes ADD CONSTRAINT notes_account_fk2 FOREIGN KEY (account_id) REFERENCES fx.accounts (id)' \
  --hold-dsn "$MIG" --hold 'UPDATE fx.accounts SET name = name WHERE false' --probe-dsn "$APP" --probe 'UPDATE fx.accounts SET name = name WHERE false' \
  --monitor-dsn "$SU" --lock-timeout 3s --hold-seconds 6 2>&1)"; rc=$?
j="$(echo "$o" | tail -1)"
echo "$j" | grep -q '"ddl":"timeout(55P03)"' && echo "$j" | grep -q '"ddl_blocked_by":"hold"' && echo "$j" | grep -q '"probe_blocked_by":"ddl"' && echo "$j" | grep -q '"observed":true,"ok":true' && [ $rc -eq 0 ] \
  && ok "locks.sh --hold:DDL 被 hold 擋住並在 lock_timeout 結束(55P03),probe(fx_app UPDATE)排在 DDL 後面($(( $(date +%s) - START ))s)" || bad "locks hold" "rc=$rc $o"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql 'SELECT 1' --hold 'SELECT 1' 2>&1)"; rc=$?
[ $rc -eq 2 ] && echo "$o" | grep -q 'superuser' && ok "locks.sh --hold:monitor 不是 superuser → 拒絕" || bad "locks monitor 權限" "rc=$rc $o"
o="$(echo "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE 'dbrev-lock-%';" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
[ "$o" = 0 ] && ok "locks.sh:結束後沒有殘留 session" || bad "locks 殘留 session" "$o"
fi

# ---------- grants ----------
cat > "$WORK/grants.txt" <<'EOF'
# label | object | action | expect
app | fx.accounts | select(id, name) | ok
app | fx.accounts | select(balance) | 42501
app | fx.accounts | insert(name) | ok
app | fx.accounts | update(name) | ok
app | fx.accounts | update(balance) | 42501
app | fx.accounts | delete | 42501
app | fx.ledger | insert | ok
app | fx.ledger | update(amount) | 42501
app | fx.events_2026_11 | select | ok
app | fx_meta.goose_db_version | select | 42501
app | fx | sql:CREATE TABLE {obj}.x (i int) | 42501
mig | fx.ledger | truncate | ok
EOF
o="$(bash "$S/grants.sh" "$N" --matrix "$WORK/grants.txt" --dsn app="$APP" --dsn mig="$MIG" 2>&1)"; rc=$?
echo "$o" | grep -q 'grants total=12 pass=12 fail=0' && [ $rc -eq 0 ] && ok "grants.sh:欄位等級 GRANT 矩陣(LOGIN DSN)12/12 符合" || bad "grants 矩陣" "$o"
printf 'app | fx.events_2026_12 | select | ok\napp | fx.nope | select | ok\n' > "$WORK/grants-bad.txt"
o="$(bash "$S/grants.sh" "$N" --matrix "$WORK/grants-bad.txt" --dsn app="$APP" 2>&1)"; rc=$?
echo "$o" | grep -q 'FAIL  app | fx.events_2026_12 | select | expect=ok got=42501' && echo "$o" | grep -q 'got=error(42P01)' && [ $rc -eq 1 ] \
  && ok "grants.sh:分區子表 ACL 不同 → 抓到 42501;表不存在 → error(42P01) 不算 ok" || bad "grants 反向" "$o"

# ---------- race ----------
cat > "$WORK/deadlock.txt" <<'EOF'
SETUP: INSERT INTO fx.accounts (name, balance) VALUES ('race-a', 100), ('race-b', 100);
A: BEGIN;
A: UPDATE fx.accounts SET balance = balance - 10 WHERE name = 'race-a';
B: BEGIN;
B: UPDATE fx.accounts SET balance = balance - 10 WHERE name = 'race-b';
A: UPDATE fx.accounts SET balance = balance + 10 WHERE name = 'race-b';
B: UPDATE fx.accounts SET balance = balance + 10 WHERE name = 'race-a';
A: COMMIT;
B: COMMIT;
CHECK: SELECT sum(balance) FROM fx.accounts WHERE name IN ('race-a', 'race-b') => 200
EOF
o="$(bash "$S/race.sh" "$N" --script "$WORK/deadlock.txt" --dsn A="$MIG" --dsn B="$MIG" --check-dsn "$SU" 2>&1)"; rc=$?
echo "$o" | tail -1 | grep -q '"deadlock":true' && echo "$o" | grep -q '40P01: deadlock detected' && [ $rc -eq 0 ] \
  && ok "race.sh:相反順序上鎖 → 偵測到 deadlock(40P01),總額不變" || bad "race deadlock" "$o"
cat > "$WORK/dup.txt" <<'EOF'
A: BEGIN;
A: INSERT INTO fx.ledger (account_id, ref, amount) SELECT id, 'credit-1', 10 FROM fx.accounts WHERE name = 'race-a';
B: BEGIN;
B: INSERT INTO fx.ledger (account_id, ref, amount) SELECT id, 'credit-1', 10 FROM fx.accounts WHERE name = 'race-a';
A: COMMIT;
B: COMMIT;
CHECK: SELECT count(*) FROM fx.ledger WHERE ref = 'credit-1' => 1
CHECK: SELECT count(*) FROM fx.ledger WHERE ref = 'credit-1' => 2
EOF
o="$(bash "$S/race.sh" "$N" --script "$WORK/dup.txt" --dsn A="$MIG" --dsn B="$APP" --check-dsn "$SU" 2>&1)"; rc=$?
echo "$o" | grep -q '^step 4 B (waiting → finished): 23505' && echo "$o" | tail -1 | grep -q '"checks":{"pass":1,"fail":1}' && [ $rc -eq 1 ] \
  && ok "race.sh:重送入帳 → 第二筆 23505(錯誤歸到正確步驟);CHECK 不符時結束碼 1" || bad "race 冪等" "$o"

BADB="$(echo "$APP" | sed 's#/fx_test?#/fx_nope?#')"
o="$(bash "$S/race.sh" "$N" --script "$WORK/dup.txt" --dsn A="$MIG" --dsn B="$BADB" --check-dsn "$SU" --step-wait 0.5 2>&1)"; rc=$?
echo "$o" | tail -1 | grep -q '"errors":{"23505":1,"connect":1}\|"errors":{"connect":1' && echo "$o" | grep -q 'session B connect failed: .*fx_nope' && echo "$o" | grep -q '^step 6 B (.*→ never-finished)' && [ $rc -ne 141 ] \
  && ok "race.sh:session B 連線失敗(資料庫不存在)→ 不被 SIGPIPE 中斷,回報連線失敗,B 的步驟標 never-finished" || bad "race session 結束" "rc=$rc $o"

printf '%s\n' "A: BEGIN; -- A starts" "A: UPDATE fx.accounts SET name = name WHERE name = 'race-a';" "B: BEGIN;" "B: UPDATE fx.accounts SET name = name WHERE name = 'race-b';" "A: COMMIT;" "B: COMMIT;" > "$WORK/clean.txt"
o="$(bash "$S/race.sh" "$N" --script "$WORK/clean.txt" --dsn A="$MIG" --dsn B="$MIG" 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$o" | tail -1 | grep -q '"deadlock":false,"errors":{}' && ok "race.sh:沒有任何錯誤時也印 JSON(errors 為空)" || bad "race 無錯誤" "rc=$rc $o"

# ---------- seed / explain ----------
o="$(bash "$S/seed.sh" "$N" --dsn "$MIG" --file "$FX/db/dev/seed-accounts.sql" --var n=2000 2>&1)"; rc=$?
cnt="$(echo "SELECT count(*) FROM fx.accounts WHERE name LIKE 'user-%';" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
[ $rc -eq 0 ] && [ "$cnt" = 2000 ] && echo "$o" | grep -q 'tmpfs_free_mb_before=' && ok "seed.sh --file:專案種子腳本(-v n=2000)" || bad "seed file" "rc=$rc cnt=$cnt $o"
o="$(bash "$S/seed.sh" "$N" --dsn "$MIG" --table fx.ledger --rows 25000 --batch 10000 --col "account_id=(SELECT min(id) FROM fx.accounts) + (g % 2000)" --col "ref='seed-'||g" --col "amount=g % 100" 2>&1)"; rc=$?
echo "$o" | grep -q 'seed table=fx.ledger rows=25000 batches=3' && [ $rc -eq 0 ] && ok "seed.sh generate_series:25,000 列分 3 批 + ANALYZE" || bad "seed generate" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "UPDATE fx.accounts SET balance = balance + 1 WHERE name = 'user-7';" --runs 8 --target-ms 1000 2>&1)"; rc=$?
bal="$(echo "SELECT balance FROM fx.accounts WHERE name = 'user-7';" | bash "$S/pg.sh" psql "$N" "$SU" -At 2>&1)"
echo "$o" | grep -q 'Buffers: shared' && echo "$o" | tail -1 | grep -q '"runs":8,"p50_ms":' && echo "$o" | tail -1 | grep -q '"ok":true' && [ "$bal" = 7 ] && [ $rc -eq 0 ] \
  && ok "explain.sh:EXPLAIN (ANALYZE, BUFFERS) + 8 次 p50/p95;DML 每次 ROLLBACK(餘額未變)" || bad "explain" "rc=$rc bal=$bal $o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SELECT count(*) FROM fx.ledger" --runs 3 --target-ms 0.0001 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | tail -1 | grep -q '"ok":false' && ok "explain.sh:p95 超過 --target-ms → 結束碼 1" || bad "explain target" "rc=$rc $o"

o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SELECT * FROM fx.no_such_table" --runs 2 2>&1)"; rc=$?
[ $rc -eq 1 ] && ok "explain.sh:SQL 錯誤 → 結束碼 1(不會被當成 Docker 沒開的 3)" || bad "explain SQL 錯誤結束碼" "rc=$rc $o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SELECT 1" --target-ms 50ms 2>&1)"; [ $? -eq 2 ] && ok "explain.sh:--target-ms 不是數字 → 用法錯誤" || bad "explain target 格式" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SELECT count(*) FROM fx.accounts; -- hot path" --runs 2 2>&1)"; [ $? -eq 0 ] && ok "explain.sh:同一行分號後的註解不算第二個語句" || bad "explain 同行註解" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SELECT 1; /* note */" --runs 2 2>&1)"; [ $? -eq 0 ] && ok "explain.sh:分號後的 /* */ 註解不算第二個語句" || bad "explain 區塊註解" "$o"
o="$(bash "$S/pg.sh" up "$N-x" --image "$IMAGE" --env POSTGRES_INITDB_WALDIR=/wal 2>&1)"; [ $? -eq 2 ] && ok "pg.sh up:POSTGRES_INITDB_WALDIR → 拒絕(WAL 也要在 tmpfs)" || bad "WALDIR" "$o"
o="$(bash "$S/pg.sh" up "$N-x" --image "$IMAGE" --timeout 2m 2>&1)"; [ $? -eq 2 ] && [ -z "$(docker ps -aq --filter "label=dbrev=$N-x")" ] && ok "pg.sh up:--timeout 不是秒數 → 用法錯誤(不啟動容器)" || bad "pg timeout" "$o"
printf 'SELECT count(*) FROM fx.accounts;\n-- hot path\n' > "$WORK/q2.sql"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --file "$WORK/q2.sql" --runs 2 2>&1)"; [ $? -eq 0 ] && ok "explain.sh:結尾分號後面接註解行也算一個語句" || bad "explain 分號+註解" "$o"
printf 'UPDATE fx.accounts SET balance = 0 \\g\nCOMMIT\n' > "$WORK/q3.sql"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --file "$WORK/q3.sql" 2>&1)"; [ $? -eq 2 ] && ok "explain.sh:查詢裡有 \\g → 拒絕" || bad "explain meta" "$o"
o="$(bash "$S/pg.sh" psql "$N" "$SU" -d "postgres://u@10.0.0.5/prod" -c 'SELECT 1' 2>&1)"; [ $? -eq 2 ] && ok "pg.sh psql:-d 等連線參數 → 拒絕" || bad "psql -d" "$o"
o="$(printf '\\c postgres://u@10.0.0.5/prod\nSELECT 1;\n' | bash "$S/pg.sh" psql "$N" "$SU" 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:stdin 裡有 \\c → 拒絕" || bad "psql \\c" "$o"
o="$(printf '\\if :{?n}\n\\else\n\\set n 1\n\\endif\n\\timing on\nSELECT :n;\n\\quit\n' | bash "$S/pg.sh" psql "$N" "$SU" -qAt 2>&1)"; [ "$(echo "$o" | head -1)" = 1 ] && ok "pg.sh psql:\\if / \\set / \\timing / \\quit 等腳本指令可以用" || bad "psql 允許的指令" "$o"
for q in 'SELECT 1 \echo $$ \! id' "SELECT E'a\\nb';" "\\echo it's
\\! id
\\echo '" "\\echo 'a\\'' \\! id" '\echo $a$ \! id $a$' '\set x `id`' '\echo -- \! id' "-- don't do this
\! id
SELECT 'x';"; do
  o="$(printf '%s\n' "$q" | bash "$S/pg.sh" psql "$N" "$SU" 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:$q → 拒絕" || bad "psql $q" "$o"
done
printf '%s\n' "A: SELECT '=>'; \\c host=10.0.0.5 dbname=prod" > "$WORK/race-bad2.txt"
o="$(bash "$S/race.sh" "$N" --script "$WORK/race-bad2.txt" --dsn A="$MIG" --dsn B="$MIG" --check-dsn "$SU" 2>&1)"; [ $? -eq 4 ] && ok "race.sh:=> 後面藏 \\c 也會被抓到" || bad "race => bypass" "$o"
printf '%s\n' 'A: BEGIN;' 'A: UPDATE fx.accounts SET name = name WHERE false' > "$WORK/race-nosemi.txt"
o="$(bash "$S/race.sh" "$N" --script "$WORK/race-nosemi.txt" --dsn A="$MIG" --dsn B="$MIG" --check-dsn "$SU" 2>&1)"; [ $? -eq 2 ] && ok "race.sh:A/B 行沒有分號 → 用法錯誤" || bad "race 無分號" "$o"
o="$(bash "$S/race.sh" "$N" --script "$WORK/clean.txt" --dsn A="$MIG" --dsn B="$APP" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q 'check-dsn' && ok "race.sh:A/B 不同角色且 check DSN 不是 superuser → 拒絕" || bad "race check-dsn 權限" "$o"
printf '%s\n' "A: SELECT 'x;" 'B: SELECT 1 \! touch /tmp/pwn;' > "$WORK/race-bad3.txt"
o="$(bash "$S/race.sh" "$N" --script "$WORK/race-bad3.txt" --dsn A="$MIG" --dsn B="$MIG" 2>&1)"; [ $? -eq 4 ] && ok "race.sh:跨 session 的未閉合引號藏不住 \\!" || bad "race 跨 session" "$o"
o="$(bash "$S/gotest.sh" "$N" --dir "$FX" -- -mod=mod ./... 2>&1)"; [ $? -eq 2 ] && ok "gotest.sh:-- 後面的 go 旗標(-mod=mod)→ 拒絕" || bad "gotest -- 旗標" "$o"
o="$(bash "$S/goose.sh" "$N" run --dir "$FX/migrations" --table fx_meta.goose_db_version --dsn "$MIG" -- -dir "$FX/migrations" fix 2>&1)"; [ $? -eq 2 ] && ok "goose.sh run:goose 旗標 / fix / create → 拒絕(不寫專案檔)" || bad "goose run 旗標" "$o"
printf '%s\n' 'A: \c host=10.0.0.5 dbname=prod' > "$WORK/race-bad.txt"
o="$(bash "$S/race.sh" "$N" --script "$WORK/race-bad.txt" --dsn A="$MIG" --dsn B="$MIG" 2>&1)"; [ $? -eq 4 ] && ok "race.sh:腳本裡有 \\c → 拒絕" || bad "race \\c" "$o"
o="$(bash "$S/race.sh" "$N" --script "$WORK/dup.txt" --dsn A="$MIG" --dsn B="$MIG" --lock-timeout 500ms 2>&1)"; [ $? -eq 2 ] && ok "race.sh:--lock-timeout ≤ 1s → 用法錯誤" || bad "race lock-timeout" "$o"
o="$(bash "$S/seed.sh" "$N" --dsn "$MIG" --table fx.ledger --rows 1 --col 'amount=1; COMMIT' 2>&1)"; [ $? -eq 2 ] && ok "seed.sh:--col 含分號 / 交易控制 → 拒絕" || bad "seed col" "$o"
o="$(bash "$S/seed.sh" "$N" --dsn "$MIG" --table fx.ledger --rows 1 --col 'amount=1 -- label' 2>&1)"; [ $? -eq 2 ] && ok "seed.sh:--col 含註解 → 拒絕" || bad "seed col 註解" "$o"
printf 'app | pg_catalog.pg_class | sql:SELECT relname FROM {obj} LIMIT 0 -- columns ok | ok\n' > "$WORK/gcm.txt"
o="$(bash "$S/grants.sh" "$N" --matrix "$WORK/gcm.txt" --dsn app="$APP" 2>&1)"; [ $? -eq 0 ] && ok "grants.sh:sql: 結尾有 -- 註解也能正確判定" || bad "grants 註解結尾" "$o"
printf '%s\n' "A: SELECT set_config('app.tenant_id', '1', false);" "B: SELECT 1;" > "$WORK/race-sc.txt"
o="$(bash "$S/race.sh" "$N" --script "$WORK/race-sc.txt" --dsn A="$MIG" --dsn B="$MIG" 2>&1)"; [ $? -eq 0 ] && ok "race.sh:一般的 set_config('app.…') 可以用" || bad "race set_config" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$APP" --query "SELECT balance FROM fx.accounts" 2>&1)"; rc=$?
[ $rc -eq 1 ] && echo "$o" | tail -1 | grep -q '"ok":false' && ok "explain.sh:第一次 EXPLAIN 失敗也印 JSON" || bad "explain 首次失敗" "rc=$rc $o"
o="$(printf 'SELECT :x;\n' | bash "$S/pg.sh" psql "$N" "$SU" -v "x=1
\\c host=10.0.0.5" 2>&1)"; [ $? -eq 2 ] && ok "pg.sh psql:-v 值跨行 → 拒絕" || bad "psql -v 跨行" "$o"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "DO \$\$BEGIN RAISE EXCEPTION '%', chr(92)||'c host=10.0.0.5'; END\$\$; SELECT :LAST_ERROR_MESSAGE;" 2>&1)"; [ $? -eq 2 ] && ok "locks.sh:裸 psql 變數(:LAST_ERROR_MESSAGE)→ 拒絕" || bad "locks 裸變數" "$o"
o="$(DBREV_SELFTEST_SKIP_TXCHECK=1 bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "CREATE TABLE fx.tmp_tok (i int); COMMIT;" 2>&1)"; rc=$?
[ $rc -eq 2 ] && ok "locks.sh:自我測試開關必須指向 token 檔(=1 無效)" || bad "locks skip token" "rc=$rc $o"
o="$(DBREV_SELFTEST_SKIP_TXCHECK="$SKIPTOK" bash "$S/locks.sh" "$N" --dsn "$MIG" --sql '\c host=10.0.0.5' 2>&1)"; [ $? -eq 2 ] && ok "locks.sh:psql 指令一律拒絕(不受自我測試開關影響)" || bad "locks 反斜線" "$o"
o="$(printf ':x\n' | bash "$S/pg.sh" psql "$N" "$SU" -v 'x=\c host=10.0.0.5 dbname=prod' 2>&1)"; [ $? -eq 2 ] && ok "pg.sh psql:-v 值含反斜線 → 拒絕" || bad "psql -v backslash" "$o"
o="$(printf "SELECT chr(92)||'! id' AS x \\gset\n:x\n" | bash "$S/pg.sh" psql "$N" "$SU" 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:\\gset 變數再以 :x 執行 → 拒絕" || bad "psql gset :x" "$o"
o="$(printf "SELECT chr(92)||'c host=10.0.0.5' AS x \\gset\n\\set y :x\n:y\n" | bash "$S/pg.sh" psql "$N" "$SU" 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:\\set y :x 複製變數再執行 → 拒絕" || bad "psql set y :x" "$o"
o="$(printf "SELECT chr(92)||'! id' AS n \\gset\n:n\n" | bash "$S/pg.sh" psql "$N" "$SU" -v n=1 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:\\gset 覆寫 -v 的變數再執行 → 拒絕" || bad "psql gset 覆寫 -v" "$o"
o="$(printf "\\set y 1\nSELECT chr(92)||'c host=evil' AS y\n\\gset\nSELECT :y;\n" | bash "$S/pg.sh" psql "$N" "$SU" 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:獨立一行的 \\gset 覆寫 \\set 變數 → 拒絕" || bad "psql 獨立 gset" "$o"
o="$(printf "SELECT chr(92)||'c h' AS y \\gset p_\nSELECT :p_y;\n" | bash "$S/pg.sh" psql "$N" "$SU" -v p_y=1 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:\\gset 前綴產生的變數 → 拒絕" || bad "psql gset prefix" "$o"
o="$(printf "SELECT :LAST_ERROR_MESSAGE;\n" | bash "$S/pg.sh" psql "$N" "$SU" -v LAST_ERROR_MESSAGE=x 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:psql 內建變數(LAST_ERROR_MESSAGE)不能裸用" || bad "psql 內建變數" "$o"
o="$(printf "SELECT :x;\n" | bash "$S/pg.sh" psql "$N" "$SU" -v x=:y 2>&1)"; [ $? -eq 2 ] && ok "pg.sh psql:-v 值含 : → 拒絕" || bad "psql -v :" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "-- TODO" 2>&1)"; [ $? -eq 2 ] && ok "explain.sh:只有註解 → 用法錯誤" || bad "explain 空查詢" "$o"
o="$(printf "SELECT :'v'::int + :n AS s;\n" | bash "$S/pg.sh" psql "$N" "$SU" -qAt -v v=1 -v n=2 2>&1)"; [ "$o" = 3 ] && ok "pg.sh psql:-v 給的 :n 與 :'v' 可以用" || bad "psql -v 變數" "$o"
o="$(printf 'SELECT 1 \\g |sh\n' | bash "$S/pg.sh" psql "$N" "$SU" 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:\\g |cmd 等不在允許清單的 psql 指令 → 拒絕" || bad "psql \\g pipe" "$o"
o="$(bash "$S/locks.sh" "$N" --dsn "$MIG" --sql "CREATE TABLE fx.tmp_n (i int); /* a /* b */ ' */ COMMIT; -- '" 2>&1)"; [ $? -eq 2 ] && ok "locks.sh:巢狀註解後的 COMMIT 也會被抓到" || bad "locks 巢狀註解" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SET work_mem='1MB'; SELECT 1" 2>&1)"; [ $? -eq 2 ] && ok "explain.sh:多個語句 → 用法錯誤" || bad "explain 多語句" "$o"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --query "SELECT 1" --runs 0 2>&1)"; [ $? -eq 2 ] && ok "explain.sh:--runs 0 → 用法錯誤(不會假通過)" || bad "explain runs 0" "$o"
printf 'SELECT count(*) FROM fx.accounts\n-- hot path' > "$WORK/q.sql"
o="$(bash "$S/explain.sh" "$N" --dsn "$MIG" --file "$WORK/q.sql" --runs 3 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$o" | tail -1 | grep -q '"runs":3' && ok "explain.sh:查詢檔最後一行是 -- 註解也能跑" || bad "explain 註解結尾" "rc=$rc $o"
for b in 0 00 000; do
  o="$(bash "$S/seed.sh" "$N" --dsn "$MIG" --table fx.ledger --rows 10 --batch $b --col "amount=g" 2>&1)"; [ $? -eq 2 ] && ok "seed.sh:--batch $b → 用法錯誤(不會無限迴圈)" || bad "seed batch $b" "$o"
done
echo 'REVOKE CONNECT ON DATABASE fx_test FROM fx_app;' | bash "$S/pg.sh" psql "$N" "$SU" -q >/dev/null 2>&1
printf 'app | fx.accounts | select(id) | 42501\n' > "$WORK/gc.txt"
o="$(bash "$S/grants.sh" "$N" --matrix "$WORK/gc.txt" --dsn app="$APP" 2>&1)"; rc=$?
echo 'GRANT CONNECT ON DATABASE fx_test TO fx_app;' | bash "$S/pg.sh" psql "$N" "$SU" -q >/dev/null 2>&1
[ $rc -eq 1 ] && echo "$o" | grep -q 'expect=42501 got=connect(42501)' && ok "grants.sh:沒有 CONNECT 時記為 connect(42501),不會冒充表層級的 42501" || bad "grants FATAL" "rc=$rc $o"
printf 'app | fx.accounts | select\n' > "$WORK/g3.txt"
o="$(bash "$S/grants.sh" "$N" --matrix "$WORK/g3.txt" --dsn app="$APP" 2>&1)"; [ $? -eq 2 ] && echo "$o" | grep -q '格式錯誤' && ok "grants.sh:只有 3 欄 → 格式錯誤" || bad "grants 3 欄" "$o"
o="$(DOCKER_HOST=tcp://192.0.2.1:2375 bash "$S/pg.sh" psql "$N" "$SU" -c 'SELECT 1' 2>&1)"; [ $? -eq 4 ] && ok "pg.sh psql:建立後 DOCKER_HOST 改成遠端 → 也拒絕(結束碼 4)" || bad "psql 非本機 docker" "$o"

# ---------- partitions ----------
o="$(bash "$S/pg.sh" psql "$N" "$SU" -v min_runway_days=100000 < "$S/partitions.sql" 2>&1)"
echo "$o" | tail -1 | grep -qx 'partitions_summary parents=1 runway_violations=1 acl_mismatches=1 missing_default=1' && echo "$o" | grep -q 'fx.events_2026_12' \
  && ok "partitions.sql:列出分區、跑道不足、子表 ACL 與父表不同(events_2026_12)、沒有 default 分區" || bad "partitions" "$o"
o="$(bash "$S/pg.sh" psql "$N" "$SU" -v min_runway_days=-100000 < "$S/partitions.sql" 2>&1 | tail -1)"
echo "$o" | grep -q 'runway_violations=0' && ok "partitions.sql:min_runway_days 變數生效" || bad "partitions 變數" "$o"

# ---------- gotest ----------
if command -v go >/dev/null 2>&1; then
o="$(DATABASE_URL=postgres://evil@10.255.255.1/x PGHOST=10.255.255.1 PGPORT=5432 PGPASSWORD=leak TEST_DATABASE_URL=postgres://x@10.0.0.1/y_test \
     bash "$S/gotest.sh" "$N" --dir "$FX" --tags integration --env FX_MIGRATOR_DSN="$MIG" --env FX_APP_DSN="$APP" -- ./migrations/ 2>&1)"; rc=$?
j="$(echo "$o" | tail -1)"
echo "$j" | grep -q '"tests": {"pass": 3, "fail": 0, "skip": 1, "total": 4}' && echo "$j" | grep -q '"status": "GAP"' && [ $rc -eq 5 ] \
  && echo "$o" | grep -q '^SKIP .*TestAuditRoleSmoke: .*FX_AUDIT_DSN not set' \
  && ok "gotest.sh:shell 帶 DATABASE_URL / PG* / TEST_* 時沒有漏進測試(TestNoAmbientConnectionEnv 通過);SKIP 1 個列原因並算缺口(結束碼 5)" || bad "gotest SKIP / 隔離" "rc=$rc $o"
o="$(bash "$S/gotest.sh" "$N" --dir "$FX" --tags integration --env FX_MIGRATOR_DSN="$MIG" --env FX_APP_DSN="$APP" --env FX_AUDIT_DSN="$APP" -- ./migrations/ 2>&1)"; rc=$?
echo "$o" | tail -1 | grep -q '"status": "PASS"' && [ $rc -eq 0 ] && ok "gotest.sh:補上 FX_AUDIT_DSN → 全部 PASS、SKIP 0(結束碼 0)" || bad "gotest PASS" "rc=$rc $o"
o="$(bash "$S/gotest.sh" "$N" --dir "$FX" --tags integration --run NoSuchTest --env FX_MIGRATOR_DSN="$MIG" -- ./migrations/ 2>&1)"; rc=$?
echo "$o" | tail -1 | grep -q 'no tests ran' && [ $rc -eq 5 ] && ok "gotest.sh:測試數 0 → 缺口(結束碼 5)" || bad "gotest 0 tests" "rc=$rc $o"
o="$(bash "$S/gotest.sh" "$N" --dir "$FX" --tags integration --env FX_MIGRATOR_DSN="postgres://fx_migrator:x@127.0.0.1:5432/fx_test" -- ./migrations/ 2>&1)"; rc=$?
[ $rc -eq 4 ] && ! ls "$DB_REVIEW_KIT_TMP/$N"/gotest-*.jsonl 2>/dev/null | xargs grep -l 'fx_migrator:x@' >/dev/null 2>&1 && ok "gotest.sh:--env DSN 指向 5432 → 執行前拒絕(結束碼 4)" || bad "gotest guard" "rc=$rc $o"
o="$(bash "$S/gotest.sh" "$N" --dir "$FX" --env DATABASE_URL="host=10.0.0.1 dbname=x" -- ./migrations/ 2>&1)"; rc=$?
[ $rc -eq 4 ] && ok "gotest.sh:--env DATABASE_URL 用 keyword 格式 → 拒絕" || bad "gotest keyword DSN" "rc=$rc $o"
o="$(bash "$S/gotest.sh" "$N" --dir "$FX" --tags integration --env FX_MIGRATOR_DSN="$MIG" --env FX_APP_DSN="$APP" --run 'TestAppColumnGrants' -- ./migrations/ 2>&1)"; rc=$?
echo "$o" | tail -1 | grep -q '"subtests": {"pass": 3, "fail": 0, "skip": 0, "total": 3}' && ok "gotest.sh:--run 分批、子測試分開計數" || bad "gotest --run" "rc=$rc $o"
fi

GIT_AFTER="$(git -C "$FX" status --porcelain -- . 2>/dev/null || echo no-git)"
[ "$GIT_BEFORE" = "$GIT_AFTER" ] && ok "fixture 專案檔案沒有被改動(git status 前後相同;go.mod / go.sum 未被改寫)" || bad "fixture 被改動" "$GIT_AFTER"

# ---------- scram on 127.0.0.1 inside the container: psql still authenticates (password via env, not argv) ----------
o="$(bash "$S/pg.sh" up "$N-scram" --image "$IMAGE" --tmpfs-size 256m --env "POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256" 2>&1)"; rc=$?
if [ $rc -eq 0 ]; then
  DS="$(bash "$S/pg.sh" dsn "$N-scram" postgres postgres)"
  o2="$(echo "SELECT 'scram-ok';" | bash "$S/pg.sh" psql "$N-scram" "$DS" -At 2>&1)"
  [ "$o2" = scram-ok ] && ok "psql:bootstrap 要求 scram 時也能連(密碼經 docker exec 環境變數傳入)" || bad "scram psql" "$o2"
else bad "scram 容器啟動" "$o"; fi
bash "$S/pg.sh" rm "$N-scram" --purge >/dev/null 2>&1

# ---------- older image (VOLUME /var/lib/postgresql/data): only when already present locally, never pulled ----------
OLD_IMAGE="${DB_REVIEW_KIT_TEST_OLD_IMAGE:-postgres:17}"
if docker image inspect "$OLD_IMAGE" >/dev/null 2>&1; then
  o="$(bash "$S/pg.sh" up "$N-old" --image "$OLD_IMAGE" --tmpfs-size 256m 2>&1)"; rc=$?
  CO="$(echo "$o" | sed -n 's/^container=\([^ ]*\) .*/\1/p')"
  if [ $rc -eq 0 ] && [ -n "$CO" ] && [ -z "$(docker inspect -f '{{range .Mounts}}{{.Type}} {{end}}' "$CO")" ] \
     && [ "$(docker inspect -f '{{index .HostConfig.Tmpfs "/var/lib/postgresql/data"}}' "$CO")" = "rw,size=256m" ]; then
    ok "pg.sh up:$OLD_IMAGE 的 tmpfs 掛在映像宣告的 /var/lib/postgresql/data,沒有匿名 volume"
  else bad "舊映像 tmpfs" "rc=$rc $o $(docker inspect -f '{{json .Mounts}} {{json .HostConfig.Tmpfs}}' "$CO" 2>&1)"; fi
  bash "$S/pg.sh" rm "$N-old" --purge >/dev/null 2>&1
else skip "舊映像 tmpfs 路徑($OLD_IMAGE 本機沒有;不自動拉)"; fi

# ---------- rm / gc ----------
o="$(bash "$S/pg.sh" rm "$N" --purge 2>&1)"
echo "$o" | grep -q "removed container=$C" && [ ! -d "$DB_REVIEW_KIT_TMP/$N" ] && ok "pg.sh rm --purge:刪容器與暫存目錄" || bad "pg.sh rm" "$o"
docker run -d --name "dbrev-$N-leftover" --label "dbrev=$N" "$IMAGE" sleep 300 >/dev/null 2>&1
docker run -d --name "other-$N" --label "dbrev=$N" "$IMAGE" sleep 300 >/dev/null 2>&1
o="$(bash "$S/pg.sh" gc "$N" 2>&1)"
if echo "$o" | grep -q "gc name=$N removed=1 remaining=0" && [ -n "$(docker ps -aq --filter "name=^/other-$N\$")" ]; then
  ok "pg.sh gc:只刪 label dbrev=$N 且名稱前綴 dbrev-$N- 的容器(同 label 但名稱不符的不刪)"
else bad "pg.sh gc" "$o"; fi
docker rm -f -v "other-$N" >/dev/null 2>&1
# only reports (never deletes) new anonymous volumes; other projects' named volumes are not touched
VOL_NEW="$(comm -13 <(echo "$VOL_BEFORE") <(docker volume ls -q --filter label=com.docker.volume.anonymous | sort))"
[ -z "$VOL_NEW" ] && ok "結束:沒有留下新的匿名 docker volume(資料都在 tmpfs)" || bad "留下匿名 volume(可能是本測試或同時執行的其他程式)" "$VOL_NEW"
[ -z "$(docker ps -aq --filter "label=dbrev=$N")" ] && ok "結束:docker ps -a --filter label=dbrev=$N 為空" || bad "殘留容器" "$(docker ps -a --filter "label=dbrev=$N")"

echo "---"
echo "pass=$PASS fail=$FAIL skip=$SKIP"
[ "$FAIL" -eq 0 ]
