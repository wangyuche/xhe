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
check "拒絕時沒有推出 feat/w" bash -c "! git -C '$TMP/remote.git' rev-parse --verify -q feat/w >/dev/null"
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
mkdir -p "$TMP/fastbin"; printf '#!/bin/sh\necho called >> "%s"\n' "$TMP/sleep.log" > "$TMP/fastbin/sleep"; chmod +x "$TMP/fastbin/sleep"
REAL_PATH=$PATH; export PATH="$TMP/fastbin:$PATH"
reset_mock() { curl -sS -X POST "$MOCK/__reset" >/dev/null; : > "$TMP/sleep.log"; }

check "mock 確實重現 bug a(jq 直接解析 MR 2 失敗)" bash -c "printf 'PRIVATE-TOKEN: glpat-full\n' | curl -sS -H @- -o '$TMP/raw2.json' '$MOCK/api/v4/projects/grp%2Fproj/merge_requests/2' && grep -q \$'\\x01' '$TMP/raw2.json' && ! jq . '$TMP/raw2.json' >/dev/null 2>&1"
check "沒有 CI 時合併,印 merge commit" bash -c "bash '$BOT' merge 1 --sha $A40 | grep -qx 'merge_commit_sha: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'"
check "控制字元 JSON 不會讓 jq 失敗(bug a)" bash -c "bash '$BOT' merge 2 --sha $A40 2>&1 | grep -q '^merged: .*/merge_requests/2$'"
reset_mock
OUT=$(bash "$BOT" merge 3 --sha "$A40" 2>&1)
check "unchecked → checking → mergeable 會等待後合併(bug b)" grep -q '^merged: .*/merge_requests/3$' <<<"$OUT"
check "bug b 確實有等待(sleep 3 次)" [ "$(wc -l < "$TMP/sleep.log" | tr -d ' ')" -eq 3 ]
reset_mock
bash "$BOT" merge 1 --sha "$A40" >/dev/null 2>&1
check "已 mergeable 時不等待" [ ! -s "$TMP/sleep.log" ]
check "merge SHA 不符拒絕" bash -c "bash '$BOT' merge 1 --sha $C40 2>&1 | grep -q '不是 review 過的'"
check "merge 短 SHA 拒絕" bash -c "! bash '$BOT' merge 1 --sha abc1234 2>/dev/null"
check "merge 缺 --sha 拒絕" bash -c "! bash '$BOT' merge 1 2>/dev/null"
check "merge has_conflicts 拒絕" bash -c "bash '$BOT' merge 4 --sha $A40 2>&1 | grep -q 'MR 有衝突'"
check "merge 已關閉拒絕" bash -c "bash '$BOT' merge 8 --sha $A40 2>&1 | grep -q '不是 open'"
for t in "5 $C40 head 有 .gitlab-ci.yml" "6 $D40 head 有 1 個 pipeline" "7 $A40 withci 有 .gitlab-ci.yml" "9 $E40 head 有 1 個 commit status"; do
  set -- $t; iid=$1 sha=$2; shift 2; msg="$*"
  : > "$TMP/req.log"
  check "merge !$iid($msg)以結束碼 2 拒絕" bash -c "bash '$BOT' merge $iid --sha $sha 2>'$TMP/err'; [ \$? -eq 2 ] && grep -qF -- '$msg' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
done

: > "$TMP/req.log"; echo '{"ci_config_path": "ci/pipeline.yml"}' > "$TMP/scenario.json"
check "merge !1(專案設自訂 ci_config_path)以結束碼 2 拒絕" bash -c "bash '$BOT' merge 1 --sha $A40 2>'$TMP/err'; [ \$? -eq 2 ] && grep -qF 'ci/pipeline.yml' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"
echo '{}' > "$TMP/scenario.json"
: > "$TMP/req.log"
check "merge !10(查詢 .gitlab-ci.yml 回 500)拒絕且不送合併" bash -c "! bash '$BOT' merge 10 --sha $F40 2>'$TMP/err' && grep -q '無法確認' '$TMP/err' && ! grep -q '^PUT' '$TMP/req.log'"

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
export PATH=$REAL_PATH

echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
