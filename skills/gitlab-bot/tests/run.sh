#!/usr/bin/env bash
# gitlab-bot 自我測試(離線:假 GitLab API + 本機 bare repo;只需 bash、python3、jq、git、curl)
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
BOT="$HERE/../scripts/bot.sh"
TMP=$(mktemp -d)
MOCK_PID=""
cleanup() { [[ -n $MOCK_PID ]] && { kill "$MOCK_PID" 2>/dev/null; wait "$MOCK_PID" 2>/dev/null; }; rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
ok()  { echo "PASS $1"; pass=$((pass + 1)); }
bad() { echo "FAIL $1"; fail=$((fail + 1)); }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1   # 不受開發者個人 git 設定影響
unset GITLAB_BOT_API_URL GITLAB_BOT_PUSH_URL GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL
export GITLAB_BOT_TOKEN_CMD="echo glpat-full"

# 工作 repo:origin 指向不存在的主機(只用來解析專案路徑),API 與 push 都改到本機
git init -q -b feat/x "$TMP/work" && cd "$TMP/work"
git remote add origin https://gitlab.example.test/grp/proj.git
echo hi > a && git add a && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git commit -q -m init
git init -q --bare "$TMP/remote.git"

# --- 測試用覆寫只接受本機(在取 token 之前就拒絕) ---
MARK="$TMP/token-fetched"
for u in http://example.com http://example.com:8080 https://127.0.0.1:1 http://127.0.0.1.evil.example:80 \
         http://localhost:1/x http://user@127.0.0.1:1 http://127.0.0.1; do
  rm -f "$MARK"
  check "GITLAB_BOT_API_URL=$u 拒絕且沒取 token" bash -c \
    "out=\$(GITLAB_BOT_TOKEN_CMD='touch $MARK; echo glpat-full' GITLAB_BOT_API_URL='$u' bash '$BOT' identity 2>&1); r=\$?
     [ \$r -ne 0 ] && grep -q '只接受' <<<\"\$out\" && [ ! -e '$MARK' ]"
done
for u in https://evil.example/x.git evil.example:grp/proj.git ssh://git@evil.example/x.git relative/path ext::sh file://evil.example/x; do
  check "GITLAB_BOT_PUSH_URL=$u 拒絕" bash -c "GITLAB_BOT_PUSH_URL='$u' bash '$BOT' push feat/x 2>&1 | grep -q '只接受本機'"
done

# --- 假 API ---
: > "$TMP/req.log"; echo '{}' > "$TMP/scenario.json"
python3 -I "$HERE/mock_api.py" "$TMP/port" "$TMP/req.log" "$TMP/scenario.json" & MOCK_PID=$!
for _ in $(seq 50); do [[ -s $TMP/port ]] && break; sleep 0.1; done
MOCK="http://127.0.0.1:$(cat "$TMP/port")"
export GITLAB_BOT_API_URL=$MOCK
check "localhost:<port> 也接受" bash -c "GITLAB_BOT_API_URL='http://localhost:$(cat "$TMP/port")' bash '$BOT' identity >/dev/null 2>&1"

# --- identity / project 與 scope ---
ID=$(bash "$BOT" identity 2>"$TMP/err"); rc=$?
check "identity 印出使用者" grep -qx 'user:     botuser' <<<"$ID"
check "identity commit_email=_private 時用 email" grep -qx 'email:    bot@example.test' <<<"$ID"
check "identity 印 token 名稱、scopes、到期日" bash -c "grep -q 'token: *xhe-bot' <<<'$ID' && grep -q 'scopes: *api, write_repository' <<<'$ID' && grep -q 'expires_at: *2027-01-31' <<<'$ID'"
check "scope 齊全時結束碼 0 且無警告" bash -c "[ $rc -eq 0 ] && [ ! -s '$TMP/err' ]"

ID=$(GITLAB_BOT_TOKEN_CMD="echo glpat-readapi" bash "$BOT" identity 2>"$TMP/err"); rc=$?
check "scope 缺 api 時結束碼 3" [ $rc -eq 3 ]
check "scope 缺 api 時仍先印完使用者資訊" grep -qx 'user:     botuser' <<<"$ID"
check "scope 缺 api 時警告 insufficient_scope" bash -c "grep -q 'api' '$TMP/err' && grep -q '403 insufficient_scope' '$TMP/err' && grep -q 'write_repository' '$TMP/err'"
echo '{"scopes": ["api"]}' > "$TMP/scenario.json"
check "只缺 write_repository 也結束碼 3" bash -c "bash '$BOT' identity >/dev/null 2>'$TMP/err'; [ \$? -eq 3 ] && grep -q '缺少 scope:write_repository' '$TMP/err'"
echo '{}' > "$TMP/scenario.json"

ID=$(GITLAB_BOT_TOKEN_CMD="echo glpat-noself" bash "$BOT" identity 2>/dev/null); rc=$?
check "self 端點 404 時印「無法確認 scope」且不失敗" bash -c "[ $rc -eq 0 ] && grep -q '無法確認 scope' <<<'$ID'"
echo '{"self_status": 500}' > "$TMP/scenario.json"
check "self 端點 500 時也不失敗" bash -c "bash '$BOT' identity 2>/dev/null | grep -q '無法確認 scope'"
echo '{}' > "$TMP/scenario.json"

PJ=$(bash "$BOT" project 2>/dev/null); rc=$?
check "project 印預設分支與受保護分支" bash -c "grep -q 'default_branch: develop' <<<'$PJ' && grep -q 'protected: *main, develop' <<<'$PJ' && grep -q 'gitlab-ci.yml:  no' <<<'$PJ'"
check "project scope 齊全時結束碼 0" [ $rc -eq 0 ]
echo '{"prot_status": 403}' > "$TMP/scenario.json"
PJ=$(bash "$BOT" project 2>/dev/null); rc=$?
check "project:protected_branches 403 時照樣印 scope、不中斷" bash -c "[ $rc -eq 0 ] && grep -q '無法查詢' <<<'$PJ' && grep -qi 'scope' <<<'$PJ'"
echo '{}' > "$TMP/scenario.json"
PJ=$(GITLAB_BOT_TOKEN_CMD="echo glpat-readapi" bash "$BOT" project 2>"$TMP/err"); rc=$?
check "project scope 缺 api 時結束碼 3 且仍印完專案資訊" bash -c "[ $rc -eq 3 ] && grep -q 'default_branch: develop' <<<'$PJ' && grep -q insufficient_scope '$TMP/err'"
check "token 錯誤時 identity 失敗(非 3)" bash -c "GITLAB_BOT_TOKEN_CMD='echo glpat-wrong' bash '$BOT' identity >/dev/null 2>&1; r=\$?; [ \$r -ne 0 ] && [ \$r -ne 3 ]"

# --- commit ---
echo b > b && git add b && bash "$BOT" commit -q -m second >/dev/null 2>&1
check "commit 作者是 token 擁有者" [ "$(git log -1 --format='%an <%ae>|%cn')" = 'Bot User <bot@example.test>|Bot User' ]

# --- push ---
export GITLAB_BOT_PUSH_URL="$TMP/remote.git"
for b in main master develop; do
  check "push $b 拒絕" bash -c "bash '$BOT' push $b 2>&1 | grep -q '拒絕直接推 $b'"
done
check "push 多餘參數(--force)拒絕" bash -c "bash '$BOT' push feat/x --force 2>&1 | grep -q '不支援其他參數'"
check "push -f 拒絕" bash -c "bash '$BOT' push feat/x -f 2>&1 | grep -q '不支援其他參數'"
check "push 缺分支拒絕" bash -c "! bash '$BOT' push 2>/dev/null"
check "push 被拒時遠端沒有任何分支" [ -z "$(git -C "$TMP/remote.git" for-each-ref)" ]

mkdir -p "$TMP/tt"
check "push 到本機 bare repo 成功" bash -c "TMPDIR='$TMP/tt' bash '$BOT' push feat/x >/dev/null 2>&1"
check "遠端分支等於 HEAD" [ "$(git -C "$TMP/remote.git" rev-parse feat/x 2>/dev/null)" = "$(git rev-parse HEAD)" ]
check ".git/config 不含 token" bash -c "! grep -rq glpat .git/config"
check "remote URL 不含 token" bash -c "! git remote -v | grep -q glpat && [ \"\$(git remote get-url origin)\" = https://gitlab.example.test/grp/proj.git ]"
check "push 後暫存目錄(含 token 檔)已刪除" [ -z "$(ls -A "$TMP/tt")" ]
check "push 後沒有寫入 credential 設定" bash -c "! git config --local --get-regexp '^credential' >/dev/null"
echo c > c && git add c && bash "$BOT" commit -q -m third >/dev/null 2>&1
check "file:// 形式的 PUSH_URL 也可推" bash -c "GITLAB_BOT_PUSH_URL='file://$TMP/remote.git' TMPDIR='$TMP/tt' bash '$BOT' push feat/y >/dev/null 2>&1 && [ \"\$(git -C '$TMP/remote.git' rev-parse feat/y)\" = \"\$(git rev-parse HEAD)\" ] && [ -z \"\$(ls -A '$TMP/tt')\" ]"
check "push 失敗(遠端不存在)時也刪除暫存目錄" bash -c "GITLAB_BOT_PUSH_URL='$TMP/nope.git' TMPDIR='$TMP/tt' bash '$BOT' push feat/z >/dev/null 2>&1; [ \$? -ne 0 ] && [ -z \"\$(ls -A '$TMP/tt')\" ]"

git config url."git@evil.example:".insteadOf https://gitlab.example.test/
check "repo 有 url.*.insteadOf 時拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --unset url."git@evil.example:".insteadOf
git config credential.helper store
check "repo 有 credential.helper 時拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --unset credential.helper
git config http.proxy http://evil.example:8080
check "repo 有 http.proxy 時拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --unset http.proxy
git config remote.https://gitlab.example.test/grp/proj.git.pushurl https://evil.example/x.git
check "repo 有 remote.<網址>.pushurl 時拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --unset remote.https://gitlab.example.test/grp/proj.git.pushurl
git config credential.https://evil.example.helper store
check "repo 有 credential.<網址>.helper 時拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --unset credential.https://evil.example.helper
git config extensions.worktreeConfig true; git config --worktree http.sslVerify false
check "config.worktree 有 http.sslVerify 時拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --worktree --unset http.sslVerify; git config --unset extensions.worktreeConfig
printf '[include]\n\tpath = %s\n' "$TMP/inc.cfg" >> .git/config; printf '[http]\n\tproxy = http://evil.example:1\n' > "$TMP/inc.cfg"
check "include 進來的 http.proxy 也拒絕 push" bash -c "bash '$BOT' push feat/w 2>&1 | grep -q '拒絕推送'"
git config --unset include.path
git config http.postBuffer 524288000
check "無害的 http.postBuffer 不擋 push" bash -c "TMPDIR='$TMP/tt' bash '$BOT' push feat/pb >/dev/null 2>&1"
git config --unset http.postBuffer
check "拒絕時沒有推出 feat/w" bash -c "! git -C '$TMP/remote.git' rev-parse --verify -q feat/w >/dev/null"
# credential helper 只綁 origin 主機、不遞迴推 submodule:用記錄參數的 git 包裝檢查實際的 push 指令
REAL_GIT=$(command -v git); mkdir -p "$TMP/gitwrap"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexec "%s" "$@"\n' "$TMP/git.log" "$REAL_GIT" > "$TMP/gitwrap/git"; chmod +x "$TMP/gitwrap/git"
: > "$TMP/git.log"
PATH="$TMP/gitwrap:$PATH" TMPDIR="$TMP/tt" bash "$BOT" push feat/v >/dev/null 2>&1
PUSHLINE=$(grep ' push ' "$TMP/git.log" | tail -1)
check "push 的 credential helper 只綁 origin 主機" bash -c "grep -q -- '-c credential.https://gitlab.example.test.helper=!f' <<<\"\$1\" && ! grep -q -- '-c credential.helper=!' <<<\"\$1\"" _ "$PUSHLINE"
check "push 停用 submodule 遞迴" bash -c "grep -q -- 'push.recurseSubmodules=no' <<<\"\$1\" && grep -q -- 'submodule.recurse=false' <<<\"\$1\" && grep -q -- 'push --no-recurse-submodules' <<<\"\$1\"" _ "$PUSHLINE"
check "push 仍推成功(feat/v)" [ "$(git -C "$TMP/remote.git" rev-parse feat/v 2>/dev/null)" = "$(git rev-parse HEAD)" ]
check "push 傳給 git 的 safe.directory 已展開 ~(HOME 換掉後才不會失效)" bash -c "H='$TMP/fakehome'; mkdir -p \$H; printf '[safe]\\n\\tdirectory = ~/repo\\n' > \$H/gc; : > '$TMP/git.log'
  HOME=\$H GIT_CONFIG_GLOBAL=\$H/gc PATH='$TMP/gitwrap:$PATH' TMPDIR='$TMP/tt' bash '$BOT' push feat/sd >/dev/null 2>&1
  grep ' push ' '$TMP/git.log' | tail -1 | grep -qF -- \"-c safe.directory=\$H/repo \""
check "push 的 safe.directory:展不開的 ~user 略過、空值清除前面項目" bash -c "H='$TMP/fakehome2'; mkdir -p \$H; printf '[safe]\\n\\tdirectory = /old\\n\\tdirectory =\\n\\tdirectory = /a\\n\\tdirectory = ~nosuchuser-xhe/x\\n\\tdirectory = /b\\n' > \$H/gc; : > '$TMP/git.log'
  HOME=\$H GIT_CONFIG_GLOBAL=\$H/gc GIT_CONFIG_NOSYSTEM=1 PATH='$TMP/gitwrap:$PATH' TMPDIR='$TMP/tt' bash '$BOT' push feat/sd2 >/dev/null 2>&1
  l=\$(grep ' push ' '$TMP/git.log' | tail -1); grep -qF -- '-c safe.directory=/a -c safe.directory=/b ' <<<\"\$l\" && ! grep -qF -e nosuchuser -e /old <<<\"\$l\""
check "不受信任的 repo(dubious ownership)拒絕 push" bash -c "! GIT_TEST_ASSUME_DIFFERENT_OWNER=1 bash '$BOT' push feat/do >/dev/null 2>&1 && ! git -C '$TMP/remote.git' rev-parse --verify -q feat/do >/dev/null"
unset GITLAB_BOT_PUSH_URL

# --- mr ---
printf 'MR 內容\n第二行\n' > "$TMP/body.md"
: > "$TMP/req.log"
check "mr 建立後印網址" [ "$(bash "$BOT" mr --head feat/x --title 'T "q"' --body-file "$TMP/body.md")" = https://gitlab.example.test/grp/proj/-/merge_requests/12 ]
check "mr 送出的 body 正確(預設 base=develop)" bash -c "grep '^POST .*/merge_requests ' '$TMP/req.log' | sed 's/^POST [^ ]* //' | jq -e '.source_branch==\"feat/x\" and .target_branch==\"develop\" and .title==\"T \\\"q\\\"\" and (.description|test(\"第二行\"))' >/dev/null"
: > "$TMP/req.log"
check "已有 open MR 時印既有網址" [ "$(bash "$BOT" mr --head feat/existing --title T)" = https://gitlab.example.test/grp/proj/-/merge_requests/5 ]
check "已有 open MR 時不重複建立(沒有 POST)" bash -c "! grep -q '^POST' '$TMP/req.log'"
check "既有 MR 的目標分支不同時不沿用,另開新的" [ "$(bash "$BOT" mr --head feat/existing --base main --title T)" != https://gitlab.example.test/grp/proj/-/merge_requests/5 ]
check "mr 缺 --title 失敗" bash -c "! bash '$BOT' mr --head feat/x 2>/dev/null"
check "mr 只有 read_api 時 403 失敗" bash -c "GITLAB_BOT_TOKEN_CMD='echo glpat-readapi' bash '$BOT' mr --head feat/x --title T 2>&1 | grep -q 'HTTP 403.*insufficient_scope'"

# --- merge(sleep 換成記錄呼叫次數的空操作)---
A40=$(printf 'a%.0s' $(seq 40)); C40=$(printf 'c%.0s' $(seq 40)); D40=$(printf 'd%.0s' $(seq 40)); E40=$(printf 'e%.0s' $(seq 40)); F40=$(printf 'f%.0s' $(seq 40))
mkdir -p "$TMP/fastbin"; printf '#!/bin/sh\necho "$1" >> "%s"\n' "$TMP/sleep.log" > "$TMP/fastbin/sleep"; chmod +x "$TMP/fastbin/sleep"
REAL_PATH=$PATH; export PATH="$TMP/fastbin:$PATH"
reset_mock() { curl -sS -X POST "$MOCK/__reset" >/dev/null; : > "$TMP/sleep.log"; }

check "mock 確實重現 bug a(jq 直接解析 MR 2 失敗)" bash -c "printf 'PRIVATE-TOKEN: glpat-full\n' | curl -sS -H @- -o '$TMP/raw2.json' '$MOCK/api/v4/projects/grp%2Fproj/merge_requests/2' && grep -q \$'\\x01' '$TMP/raw2.json' && ! jq . '$TMP/raw2.json' >/dev/null 2>&1"
check "沒有 CI 時合併,印 merge commit" bash -c "bash '$BOT' merge 1 --sha $A40 | grep -qx 'merge_commit_sha: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
check "控制字元 JSON 不會讓 jq 失敗(bug a)" bash -c "bash '$BOT' merge 2 --sha $A40 2>&1 | grep -q '^merged: .*/merge_requests/2$'"
reset_mock
OUT=$(bash "$BOT" merge 3 --sha "$A40" 2>&1)
check "unchecked → checking → mergeable 會等待後合併(bug b)" grep -q '^merged: .*/merge_requests/3$' <<<"$OUT"
check "bug b 確實有等待(sleep 3 次)" [ "$(grep -cx 3 "$TMP/sleep.log")" -eq 3 ]
reset_mock
: > "$TMP/req.log"
bash "$BOT" merge 1 --sha "$A40" >/dev/null 2>&1
check "已 mergeable 時不等待合併狀態" [ "$(grep -cx 3 "$TMP/sleep.log")" -eq 0 ]
check "等晚登記的 CI:查 4 次、間隔 5 秒共 3 次" [ "$(grep -cx 5 "$TMP/sleep.log")" -eq 3 ]
check "合併前再確認一次 CI(head statuses 共查 5 次)" [ "$(grep -c "^GET .*/repository/commits/$A40/statuses" "$TMP/req.log")" -eq 5 ]
check "目標分支的 commit 也查 pipeline 與 commit status" bash -c "grep -q 'pipelines?sha=2222222222222222222222222222222222222222' '$TMP/req.log' && grep -q 'commits/2222222222222222222222222222222222222222/statuses' '$TMP/req.log'"
reset_mock
check "剛 push 完(第一次 GET 是舊 sha / 衝突)仍等重新計算後合併" bash -c "bash '$BOT' merge 17 --sha $A40 2>&1 | grep -q '^merged: .*/merge_requests/17$'"
check "GitLab 狀態 ci_still_running 時以結束碼 4 拒絕" bash -c "bash '$BOT' merge 18 --sha $A40 2>'$TMP/err'; [ \$? -eq 4 ] && grep -q 'ci_still_running' '$TMP/err'"
check "merge SHA 不符拒絕" bash -c "bash '$BOT' merge 1 --sha $C40 2>&1 | grep -q '不是 review 過的'"
check "merge 短 SHA 拒絕" bash -c "! bash '$BOT' merge 1 --sha abc1234 2>/dev/null"
check "merge 缺 --sha 拒絕" bash -c "! bash '$BOT' merge 1 2>/dev/null"
check "merge has_conflicts 拒絕" bash -c "bash '$BOT' merge 4 --sha $A40 2>&1 | grep -q 'MR 有衝突'"
check "merge 已關閉拒絕" bash -c "bash '$BOT' merge 8 --sha $A40 2>&1 | grep -q '不是 open'"
reset_mock
for t in "5 $C40 head 有 .gitlab-ci.yml" "6 $D40 head 有 1 個 pipeline" "7 $A40 withci 有 .gitlab-ci.yml" "9 $E40 head 有 1 個 commit status" \
         "11 0000000000000000000000000000000000000000 head 有 1 個 pipeline" "13 $A40 tgtci 有 1 個 commit status" "14 $A40 MR 有 1 個 pipeline"; do
  set -- $t; iid=$1 sha=$2; shift 2; msg="$*"
  : > "$TMP/req.log"
  check "merge !$iid($msg,還沒有通過的 pipeline)以結束碼 4 拒絕" bash -c "bash '$BOT' merge $iid --sha $sha 2>'$TMP/err'; [ \$? -eq 4 ] && grep -qF -- '$msg' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
done

: > "$TMP/req.log"; echo '{"ci_config_path": "ci/pipeline.yml"}' > "$TMP/scenario.json"
check "merge !1(專案設自訂 ci_config_path)以結束碼 4 拒絕" bash -c "bash '$BOT' merge 1 --sha $A40 2>'$TMP/err'; [ \$? -eq 4 ] && grep -qF 'ci/pipeline.yml' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
for kv in "auto_devops_enabled Auto DevOps" "only_allow_merge_if_pipeline_succeeds pipeline 成功"; do
  set -- $kv; key=$1; shift; msg="$*"
  echo "{\"$key\": true}" > "$TMP/scenario.json"; : > "$TMP/req.log"
  check "merge !1($key)以結束碼 4 拒絕" bash -c "bash '$BOT' merge 1 --sha $A40 2>'$TMP/err'; [ \$? -eq 4 ] && grep -qF '$msg' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
done
echo '{}' > "$TMP/scenario.json"
: > "$TMP/req.log"
check "merge !10(查詢 .gitlab-ci.yml 回 500)拒絕且不送合併" bash -c "! bash '$BOT' merge 10 --sha $F40 2>'$TMP/err' && grep -q '無法確認' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
N40=$(printf '9%.0s' $(seq 40))
check "merge !15(查詢 pipelines 回 500)拒絕且不送合併" bash -c "bash '$BOT' merge 15 --sha $N40 2>'$TMP/err'; r=\$?; [ \$r -ne 0 ] && [ \$r -ne 2 ] && grep -q '查不到 head 的 pipeline' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
check "merge !16(目標分支查不到)拒絕且不送合併" bash -c "! bash '$BOT' merge 16 --sha $A40 2>'$TMP/err' && grep -q '查不到目標分支 gone' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
for k in ci_config_path auto_devops_enabled only_allow_merge_if_pipeline_succeeds; do
  echo "{\"hide_fields\": [\"$k\"]}" > "$TMP/scenario.json"; : > "$TMP/req.log"
  check "merge !1(專案回應沒有 $k,Developer 權限)以結束碼 4 拒絕" bash -c "bash '$BOT' merge 1 --sha $A40 2>'$TMP/err'; [ \$? -eq 4 ] && grep -qF '沒有 $k 欄位' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
done
echo '{"auto_devops_enabled": "yes"}' > "$TMP/scenario.json"; : > "$TMP/req.log"
check "merge !1(布林欄位值異常)以結束碼 4 拒絕" bash -c "bash '$BOT' merge 1 --sha $A40 2>'$TMP/err'; [ \$? -eq 4 ] && grep -qF '無法確認' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
echo '{}' > "$TMP/scenario.json"

# --- 有 CI:pipeline 通過才合併 ---
S=$(printf '4%.0s' $(seq 40)); reset_mock; : > "$TMP/req.log"
check "merge !19(pipeline 通過;舊的失敗已重跑成功;allow_failure / manual 不擋)合併" bash -c "bash '$BOT' merge 19 --sha $S 2>'$TMP/err' | grep -q '^merged: .*/merge_requests/19$'"
check "merge !19 送出的合併鎖 head SHA" bash -c "grep '^PUT .*/merge_requests/19/merge ' '$TMP/req.log' | sed 's/^PUT [^ ]* //' | jq -e '.sha==\"$S\"' >/dev/null"
S=$(printf '5%.0s' $(seq 40)); : > "$TMP/req.log"
check "merge !20(head pipeline failed)以結束碼 2 拒絕" bash -c "bash '$BOT' merge 20 --sha $S 2>'$TMP/err'; [ \$? -eq 2 ] && grep -q 'CI 沒有通過' '$TMP/err' && grep -q 'failed' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
S=$(printf '6%.0s' $(seq 40)); reset_mock; : > "$TMP/req.log"
check "merge !21(CI 還在跑、不等)以結束碼 4 拒絕" bash -c "bash '$BOT' merge 21 --sha $S 2>'$TMP/err'; [ \$? -eq 4 ] && grep -q 'CI 還在跑' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
reset_mock; : > "$TMP/req.log"
check "merge !21 --wait-ci 5:等 CI 跑完後合併" bash -c "bash '$BOT' merge 21 --sha $S --wait-ci 5 2>'$TMP/err' | grep -q '^merged: .*/merge_requests/21$'"
check "merge !21 等待時每 30 秒查一次" [ "$(grep -cx 30 "$TMP/sleep.log")" -ge 1 ]
check "merge --wait-ci 不是整數時拒絕" bash -c "! bash '$BOT' merge 21 --sha $S --wait-ci abc 2>/dev/null"
S=$(printf '7%.0s' $(seq 40)); : > "$TMP/req.log"
check "merge !22(外部 commit status failed)以結束碼 2 拒絕" bash -c "bash '$BOT' merge 22 --sha $S 2>'$TMP/err'; [ \$? -eq 2 ] && grep -q 'jenkins failed' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
S=$(printf '8%.0s' $(seq 40)); : > "$TMP/req.log"
check "merge !23(head pipeline 是舊 head 的)以結束碼 4 拒絕" bash -c "bash '$BOT' merge 23 --sha $S 2>'$TMP/err'; [ \$? -eq 4 ] && grep -q '還不是' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
: > "$TMP/req.log"
check "merge !24(merged results pipeline 通過)合併" bash -c "bash '$BOT' merge 24 --sha $A40 2>'$TMP/err' | grep -q '^merged: .*/merge_requests/24$'"

# --- jobs / log / retry ---
check "jobs 列出 job 與 allow_failure" bash -c "out=\$(bash '$BOT' jobs 50); grep -qx $'501\ttest\tgo-test\tfailed' <<<\"\$out\" && grep -q 'lint.*(allow_failure)' <<<\"\$out\""
check "log 只印最後幾行、去掉色碼與 section 標記" bash -c "out=\$(bash '$BOT' log 501 3); [ \$(wc -l <<<\"\$out\") -eq 3 ] && grep -qx -- '--- FAIL: TestX' <<<\"\$out\" && grep -qx 'ERROR: Job failed' <<<\"\$out\" && ! grep -q \$'\\x1b' <<<\"\$out\""
check "log 預設 200 行" bash -c "[ \$(bash '$BOT' log 501 | wc -l) -eq 200 ]"
check "log 行數超過上限拒絕" bash -c "! bash '$BOT' log 501 99999 2>/dev/null"
: > "$TMP/req.log"
check "retry 送 POST 並印狀態" bash -c "[ \"\$(bash '$BOT' retry 50)\" = 'pipeline #50 pending' ] && grep -q '^POST .*/pipelines/50/retry' '$TMP/req.log'"

# --- 反向驗證:在暫存複本上拿掉修正,對應測試必須失敗 ---
mkdir -p "$TMP/mut"
mutate() {  # mutate <名稱> <python 取代式:舊字串> <新字串>
  python3 -I -c 'import sys;s=open(sys.argv[1]).read();assert sys.argv[2] in s, "pattern missing";open(sys.argv[3],"w").write(s.replace(sys.argv[2],sys.argv[4]))' \
    "$BOT" "$2" "$TMP/mut/$1.sh" "$3"
}
mutate nolenient "python3 -I -c 'import sys,json;json.dump(json.loads(sys.stdin.buffer.read().decode(\"utf-8\"),strict=False),sys.stdout,ensure_ascii=False)' <\"\$out\"" 'cat "$out"'
check "反向驗證:拿掉寬鬆解析 → bug a 測試失敗" bash -c "! cmp -s '$BOT' '$TMP/mut/nolenient.sh' && ! bash '$TMP/mut/nolenient.sh' merge 2 --sha $A40 2>/dev/null | grep -q '^merged:'"
check "反向驗證:拿掉寬鬆解析 → 一般 MR 仍可合併(變異只影響控制字元)" bash -c "bash '$TMP/mut/nolenient.sh' merge 1 --sha $A40 2>/dev/null | grep -q '^merged:'"
mutate nopoll 'for _ in $(seq 1 20); do' 'for _ in $(seq 1 1); do'
reset_mock
check "反向驗證:拿掉輪詢 → bug b 測試失敗" bash -c "! cmp -s '$BOT' '$TMP/mut/nopoll.sh' && bash '$TMP/mut/nopoll.sh' merge 3 --sha $A40 2>&1 | grep -q '無法合併:unchecked'"
mutate norecheck '?with_merge_status_recheck=true' ''
reset_mock
check "反向驗證:拿掉 with_merge_status_recheck → bug b 測試失敗" bash -c "! cmp -s '$BOT' '$TMP/mut/norecheck.sh' && bash '$TMP/mut/norecheck.sh' merge 3 --sha $A40 2>&1 | grep -q '無法合併:unchecked'"
mutate nolate 'for i in 1 2 3 4; do' 'for i in 1; do'
reset_mock
check "反向驗證:拿掉等待晚登記 CI → !11 會被合併" bash -c "! cmp -s '$BOT' '$TMP/mut/nolate.sh' && bash '$TMP/mut/nolate.sh' merge 11 --sha 0000000000000000000000000000000000000000 2>/dev/null | grep -q '^merged:'"
mutate nofields 'for k in ci_config_path auto_devops_enabled only_allow_merge_if_pipeline_succeeds; do' 'for k in; do'
echo '{"hide_fields": ["auto_devops_enabled"]}' > "$TMP/scenario.json"
check "反向驗證:拿掉缺欄位檢查 → Developer 權限時會被合併" bash -c "! cmp -s '$BOT' '$TMP/mut/nofields.sh' && bash '$TMP/mut/nofields.sh' merge 1 --sha $A40 2>/dev/null | grep -q '^merged:'"
echo '{}' > "$TMP/scenario.json"
mutate okall 'else "bad" end;' 'else "ok" end;'
check "反向驗證:失敗的 CI 當成通過 → !20 會被合併" bash -c "! cmp -s '$BOT' '$TMP/mut/okall.sh' && bash '$TMP/mut/okall.sh' merge 20 --sha $(printf '5%.0s' $(seq 40)) 2>/dev/null | grep -q '^merged:'"
mutate oldest 'map(max_by(.id)' 'map(min_by(.id)'
check "反向驗證:每個 ref 取最舊的 pipeline → !19 不會被合併" bash -c "! cmp -s '$BOT' '$TMP/mut/oldest.sh' && ! bash '$TMP/mut/oldest.sh' merge 19 --sha $(printf '4%.0s' $(seq 40)) 2>/dev/null | grep -q '^merged:'"
mutate nohead '.sha == $s or' 'true or'
check "反向驗證:不檢查 head pipeline 是哪個 head 的 → !23 會被合併" bash -c "! cmp -s '$BOT' '$TMP/mut/nohead.sh' && bash '$TMP/mut/nohead.sh' merge 23 --sha $(printf '8%.0s' $(seq 40)) 2>/dev/null | grep -q '^merged:'"
export PATH=$REAL_PATH

echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
