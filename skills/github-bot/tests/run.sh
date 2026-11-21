#!/usr/bin/env bash
# github-bot 自我測試(離線:本機產生 RSA 金鑰 + 假 GitHub API)
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

openssl genrsa -traditional -out "$TMP/key.pem" 2048 2>/dev/null || openssl genrsa -out "$TMP/key.pem" 2048 2>/dev/null
openssl rsa -in "$TMP/key.pem" -pubout -out "$TMP/pub.pem" 2>/dev/null
printf 'APP_ID=123456\nKEY_FILE=%s\n' "$TMP/key.pem" > "$TMP/config"
export GITHUB_BOT_CONFIG="$TMP/config"
export GITHUB_BOT_TEST=1   # 允許 _ 開頭的測試用子指令
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1   # 不受開發者個人 git 設定(gpgsign 等)影響
unset GITHUB_BOT_APP_ID GITHUB_BOT_KEY_FILE GITHUB_BOT_GH_USER GITHUB_BOT_TOKEN_FILE GITHUB_BOT_API_URL \
      GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL

# --- JWT ---
J=$(bash "$BOT" _jwt)
IFS=. read -r JH JP JS <<<"$J"
unb64() { local s; s=$(printf '%s' "$1" | tr -- '-_' '+/'); while (( ${#s} % 4 )); do s+="="; done; printf '%s' "$s" | openssl base64 -d -A; }
check "jwt header RS256" [ "$(unb64 "$JH" | jq -r .alg)" = RS256 ]
check "jwt iss = APP_ID" [ "$(unb64 "$JP" | jq -r .iss)" = 123456 ]
check "jwt exp ≤ 10 分鐘" [ $(( $(unb64 "$JP" | jq -r '.exp - .iat') )) -le 600 ]
unb64 "$JS" > "$TMP/sig"
check "jwt 簽章可用公鑰驗證" bash -c "printf '%s' '$JH.$JP' | openssl dgst -sha256 -verify '$TMP/pub.pem' -signature '$TMP/sig' >/dev/null"

# --- 設定錯誤 ---
check "缺 APP_ID 會失敗" bash -c "GITHUB_BOT_CONFIG=/nonexistent bash '$BOT' _jwt 2>/dev/null; [ \$? -ne 0 ]"
check "環境變數覆蓋設定檔" bash -c "GITHUB_BOT_APP_ID=999 bash '$BOT' _jwt | cut -d. -f2 | tr -- '-_' '+/' | { read s; while (( \${#s} % 4 )); do s+='='; done; printf %s \"\$s\"; } | openssl base64 -d -A | jq -e '.iss==\"999\"' >/dev/null"

# --- 網址解析 ---
check "parse https" [ "$(bash "$BOT" _parse https://github.com/wangyuche/xhe.git)" = wangyuche/xhe ]
check "parse ssh"   [ "$(bash "$BOT" _parse git@github.com:wangyuche/xhe.git)" = wangyuche/xhe ]
check "parse 無 .git" [ "$(bash "$BOT" _parse https://github.com/a/b)" = a/b ]
check "非 GitHub 拒絕" bash -c "! bash '$BOT' _parse https://gitlab.com/a/b"
check "evilgithub.com 拒絕" bash -c "! bash '$BOT' _parse git@evilgithub.com:o/r.git"
check "github.com.example 拒絕" bash -c "! bash '$BOT' _parse https://github.com.example/o/r"
check "ssh:// 網址" [ "$(bash "$BOT" _parse ssh://git@github.com/a/b.git)" = a/b ]
check "repo 名稱怪字元拒絕" bash -c "! bash '$BOT' _parse 'https://github.com/a/b?x'"
check "ssh.github.com:443" [ "$(bash "$BOT" _parse ssh://git@ssh.github.com:443/a/b.git)" = a/b ]
check "結尾斜線" [ "$(bash "$BOT" _parse https://github.com/a/b/)" = a/b ]
printf 'APP_ID = "123456" \nKEY_FILE="%s"\n' "$TMP/key.pem" > "$TMP/config-quoted"
check "設定值去引號與空白" bash -c "GITHUB_BOT_CONFIG='$TMP/config-quoted' bash '$BOT' _jwt >/dev/null"
check "API 網址限制" bash -c "GITHUB_BOT_API_URL=http://attacker.example bash '$BOT' --repo o/r token 2>&1 | grep -q '只能是'"
printf 'APP_ID=123456  # my app\nKEY_FILE=%s\n' "$TMP/key.pem" > "$TMP/config-comment"
printf 'APP_ID=123456\nKEY_FILE="%s"\n' "$TMP/k #1.pem" > "$TMP/config-hash"; cp "$TMP/key.pem" "$TMP/k #1.pem"
check "引號內的 # 不當註解" bash -c "GITHUB_BOT_CONFIG='$TMP/config-hash' bash '$BOT' _jwt >/dev/null"
printf 'APP_ID=123456\nKEY_FILE="%s" # app key\n' "$TMP/key.pem" > "$TMP/config-qc"
check "引號值加行尾註解" bash -c "GITHUB_BOT_CONFIG='$TMP/config-qc' bash '$BOT' _jwt >/dev/null"
cp "$TMP/key.pem" "$TMP/keyeq="; printf 'APP_ID=123456\nKEY_FILE=%s\n' "$TMP/keyeq=" > "$TMP/config-eq"
check "值結尾的 = 保留(bash 3.2)" bash -c "GITHUB_BOT_CONFIG='$TMP/config-eq' /bin/bash '$BOT' _jwt >/dev/null"
check "設定行尾註解" bash -c "GITHUB_BOT_CONFIG='$TMP/config-comment' bash '$BOT' _jwt >/dev/null"
check "--repo 缺值不 crash" bash -c "bash '$BOT' --repo 2>&1 | grep -q '後面要接值'"
check "--repo 格式錯誤拒絕" bash -c "! bash '$BOT' --repo 'bad repo' token 2>/dev/null"

# --- 假 API ---
python3 -I "$HERE/mock_api.py" "$TMP/port" & MOCK_PID=$!
for _ in $(seq 50); do [[ -s $TMP/port ]] && break; sleep 0.1; done
export GITHUB_BOT_API_URL="http://127.0.0.1:$(cat "$TMP/port")"

check "token" [ "$(bash "$BOT" --repo o/r token)" = ghs_testtoken ]
check "App 未安裝時失敗" bash -c "! bash '$BOT' --repo o/missing token 2>/dev/null"
ID=$(bash "$BOT" --repo o/r identity)
check "identity name"  grep -qx 'name=xhe-bot\[bot\]' <<<"$ID"
check "identity email" grep -qx 'email=12345+xhe-bot\[bot\]@users.noreply.github.com' <<<"$ID"

printf 'PR 內容\n第二行\n' > "$TMP/body.md"
check "pr 回傳網址" [ "$(bash "$BOT" --repo o/r pr --head feat/x --title 'T "q"' --body-file "$TMP/body.md")" = https://github.com/o/r/pull/7 ]
check "--repo 去掉 .git" [ "$(bash "$BOT" --repo o/r.git pr --head feat/x --title T)" = https://github.com/o/r/pull/7 ]
check "已有 open PR 時印出既有網址" [ "$(bash "$BOT" --repo o/r pr --head feat/existing --title T)" = https://github.com/o/r/pull/5 ]
check "pr 缺 title 失敗" bash -c "! bash '$BOT' --repo o/r pr --head feat/x 2>/dev/null"

check "push main 拒絕"   bash -c "! bash '$BOT' --repo o/r push main 2>/dev/null"
check "push master 拒絕" bash -c "! bash '$BOT' --repo o/r push master 2>/dev/null"
check "push 預設分支拒絕" bash -c "bash '$BOT' --repo o/r push develop 2>&1 | grep -q '不推預設分支'"
for b in HEAD refs/heads/main 'a..b' x.lock; do
  check "push 分支名 $b 拒絕" bash -c "bash '$BOT' --repo o/r push '$b' 2>&1 | grep -q 不合法"
done
check "push 選項式分支名拒絕" bash -c "! bash '$BOT' --repo o/r push --force 2>/dev/null"

printf 'GH_USER=xhe-bot\n' > "$TMP/config-gh0"; printf 'ghp_testpat\n' > "$TMP/pat0"
A40=$(printf 'a%.0s' $(seq 40)); B40=$(printf 'b%.0s' $(seq 40)); C40=$(printf 'c%.0s' $(seq 40))
# merge 會輪詢確認沒有 CI;測試把 sleep 換成空操作
mkdir -p "$TMP/fastbin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/fastbin/sleep"; chmod +x "$TMP/fastbin/sleep"
mkdir -p "$TMP/slbin"; printf '#!/bin/sh\necho called >> "%s"\n' "$TMP/sleep.log" > "$TMP/slbin/sleep"; chmod +x "$TMP/slbin/sleep"
REAL_PATH=$PATH; export PATH="$TMP/fastbin:$PATH"
A40=$(printf 'a%.0s' $(seq 40)); B40=$(printf 'b%.0s' $(seq 40)); C40=$(printf 'c%.0s' $(seq 40))
sha_of() { printf "$1%.0s" $(seq 40); }
check "沒有 CI 時合併,回傳 merge commit" [ "$(bash "$BOT" --repo o/r merge 7 --sha "$A40")" = "$B40" ]
check "merge SHA 不符拒絕" bash -c "bash '$BOT' --repo o/r merge 7 --sha $C40 2>&1 | grep -q '重新 review'"
check "merge 缺 --sha 拒絕" bash -c "! bash '$BOT' --repo o/r merge 7 2>/dev/null"
check "merge 短 SHA 拒絕" bash -c "! bash '$BOT' --repo o/r merge 7 --sha abc1234 2>/dev/null"
check "merge 缺值不 crash" bash -c "bash '$BOT' --repo o/r merge 7 --sha 2>&1 | grep -q '後面要接值'"
check "merge 不明 method 拒絕" bash -c "! bash '$BOT' --repo o/r merge 7 --sha $A40 --method octopus 2>/dev/null"
check "merge 有衝突拒絕" bash -c "bash '$BOT' --repo o/r merge 8 --sha $A40 2>&1 | grep -q '有衝突'"
check "merge GitHub 說 unstable 拒絕" bash -c "bash '$BOT' --repo o/r merge 9 --sha $A40 2>&1 | grep -q '失敗或未完成的檢查'"
: > "$TMP/sleep.log"
check "merge closed 立即拒絕(不輪詢)" bash -c "PATH='$TMP/slbin:$PATH' bash '$BOT' --repo o/r merge 10 --sha $A40 2>&1 | grep -q '不是 open' && [ ! -s '$TMP/sleep.log' ]"
check "有空的 check suite 就不自動合併" bash -c "bash '$BOT' --repo o/r merge 11 --sha $(sha_of 1) 2>&1 | grep -q 'check suite(1)'"
check "有 check run 就不自動合併" bash -c "bash '$BOT' --repo o/r merge 12 --sha $(sha_of 2) 2>&1 | grep -q 'check run(1)'"
check "有 commit status 就不自動合併" bash -c "bash '$BOT' --repo o/r merge 13 --sha $(sha_of 3) 2>&1 | grep -q 'commit status(1)'"
check "有 workflow run 就不自動合併" bash -c "bash '$BOT' --repo o/r merge 14 --sha $(sha_of 4) 2>&1 | grep -q 'workflow run(1)'"
check "有 .github/workflows 就不自動合併" bash -c "bash '$BOT' --repo o/r merge 15 --sha $(sha_of 5) 2>&1 | grep -q '.github/workflows(1 個檔案)'"
check "workflows 查詢失敗時拒絕(fail closed)" bash -c "bash '$BOT' --repo o/r merge 16 --sha $(sha_of 6) 2>&1 | grep -q '查不到 repo 是否有 workflow'"
check "等待期間才登記的 CI 也擋" bash -c "bash '$BOT' --repo o/r merge 17 --sha $(sha_of 7) 2>&1 | grep -q '有 CI(.*commit status(1)'"
check "合併前最後一次才出現的 CI 也擋" bash -c "bash '$BOT' --repo o/r merge 18 --sha $(sha_of 8) 2>&1 | grep -q '合併前偵測到 CI'"
: > "$TMP/sleep.log"
(PATH="$TMP/slbin:$PATH" bash "$BOT" --repo o/r merge 7 --sha "$A40" >/dev/null 2>&1)
check "沒有 CI 時也先等 15 秒(3 次 sleep)確認" [ "$(wc -l < "$TMP/sleep.log")" -eq 3 ]
export PATH=$REAL_PATH

# --- push 用的 git 參數 ---
git init -q "$TMP/prepo"
CRED=$(cd "$TMP/prepo" && printf 'protocol=https\nhost=github.com\n\n' | bash "$BOT" _pushgit tok123 botuser credential fill)
check "credential 給 bot token" grep -qx 'password=tok123' <<<"$CRED"
check "credential 給 bot 使用者" grep -qx 'username=botuser' <<<"$CRED"
check "token 不在 git 子程序環境" bash -c "cd '$TMP/prepo' && ! bash '$BOT' _pushgit tok123 u -c alias.envdump='!env' envdump | grep -q tok123"
printf '[url "git@github.com:"]\n\tinsteadOf = https://github.com/\n' > "$TMP/gitconfig-ssh"
check "忽略全域 insteadOf" [ "$(cd "$TMP/prepo" && GIT_CONFIG_GLOBAL="$TMP/gitconfig-ssh" bash "$BOT" _pushgit t u ls-remote --get-url https://github.com/o/r.git)" = https://github.com/o/r.git ]
mkdir -p "$TMP/tt"
(cd "$TMP/prepo" && TMPDIR="$TMP/tt" bash "$BOT" _pushgit t u status >/dev/null 2>&1)
check "token 暫存檔結束後刪除" [ -z "$(ls -A "$TMP/tt")" ]
(cd "$TMP/prepo" && TMPDIR="$TMP/tt" bash "$BOT" _pushgit t u nosuchcmd >/dev/null 2>&1)
check "失敗時也刪除 token 暫存檔" [ -z "$(ls -A "$TMP/tt")" ]
printf 'machine github.com login me password ghp_personal\n' > "$TMP/.netrc"
check "推送時 HOME 不是使用者的(不讀 ~/.netrc)" bash -c "cd '$TMP/prepo' && h=\$(HOME='$TMP' bash '$BOT' _pushgit t u -c alias.h='!printf %s \"\$HOME\"' h) && [ \"\$h\" != '$TMP' ] && [ ! -e \"\$h/.netrc\" ]"
mkdir -p "$TMP/sigterm"
( bash "$BOT" _scratch hang > "$TMP/sigterm/out" & p=$!; /bin/sleep 0.5; kill -TERM $p; wait $p 2>/dev/null ) || true
sed -n 1p "$TMP/sigterm/out" > "$TMP/sigterm/dir"; CHILD=$(sed -n 2p "$TMP/sigterm/out")
check "中斷後不留下子程序" bash -c "[ -n '$CHILD' ] && ! kill -0 '$CHILD' 2>/dev/null"
check "被 SIGTERM 中斷也刪除暫存目錄" bash -c "d=\$(cat '$TMP/sigterm/dir'); [ -n \"\$d\" ] && [ ! -e \"\$d\" ]"
printf 'not a key\n' > "$TMP/badkey.pem"
check "私鑰壞掉時明確報錯" bash -c "GITHUB_BOT_APP_ID=1 GITHUB_BOT_KEY_FILE='$TMP/badkey.pem' bash '$BOT' _jwt 2>&1 | grep -q '私鑰簽章失敗'"
git init -q "$TMP/lfsrepo" && (cd "$TMP/lfsrepo" && printf '*.png filter=lfs diff=lfs merge=lfs -text\n' > .gitattributes && git add .gitattributes && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t git commit -q -m lfs) >/dev/null 2>&1
check "Git LFS repo 拒絕推送" bash -c "cd '$TMP/lfsrepo' && bash '$BOT' --repo o/r push feat/x 2>&1 | grep -q 'Git LFS'"
check "停用 hooks" [ "$(cd "$TMP/prepo" && bash "$BOT" _pushgit t u config core.hooksPath)" = /dev/null ]
check "credential 不受 extraheader 影響" [ "$(cd "$TMP/prepo" && bash "$BOT" _pushgit t u config --get-all http.extraHeader | tail -1)" = "" ]
printf '[url "git@github.com:"]\n\tpushInsteadOf = https://github.com/\n' > "$TMP/prepo/.git/extra.cfg"
git -C "$TMP/prepo" config include.path extra.cfg
check "include 的 url.* 拒絕" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u status 2>&1 | grep -q '請先移除'"
git -C "$TMP/prepo" config --unset include.path
git -C "$TMP/prepo" config http.https://github.com/.extraheader 'AUTHORIZATION: basic xxx'
check "extraheader 拒絕" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u status 2>&1 | grep -q extraheader"
git -C "$TMP/prepo" config --unset http.https://github.com/.extraheader
check "GIT_CONFIG_COUNT 注入無效" bash -c "cd '$TMP/prepo' && [ \"\$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.git@github.com:.insteadOf GIT_CONFIG_VALUE_0=https://github.com/ bash '$BOT' _pushgit t u ls-remote --get-url https://github.com/o/r.git)\" = https://github.com/o/r.git ]"
git -C "$TMP/prepo" config url."git@github.com:".insteadOf https://github.com/
check "repo 有 url.* 設定拒絕" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u ls-remote --get-url x 2>&1 | grep -q insteadof"
check "GIT_CONFIG 繞不過檢查" bash -c "cd '$TMP/prepo' && : > '$TMP/empty.cfg' && GIT_CONFIG='$TMP/empty.cfg' bash '$BOT' _pushgit t u status 2>&1 | grep -q insteadof"
git -C "$TMP/prepo" config --unset url."git@github.com:".insteadOf
for kv in http.proxy=http://evil:8080 http.sslVerify=false http.https://github.com/.proxy=http://evil credential.https://github.com.helper=evil; do
  git -C "$TMP/prepo" config "${kv%%=*}" "${kv#*=}"
  check "拒絕 ${kv%%=*}" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u status 2>&1 | grep -q '請先移除'"
  git -C "$TMP/prepo" config --unset "${kv%%=*}"
done
git -C "$TMP/prepo" config extensions.worktreeConfig true
git -C "$TMP/prepo" config --worktree http.https://github.com/.proxy http://evil:1
check "worktree 設定的 http.* 拒絕" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u status 2>&1 | grep -q '請先移除'"
git -C "$TMP/prepo" config --worktree --unset http.https://github.com/.proxy
check "SSL_CERT_FILE / CURL_CA_BUNDLE 被移除" [ -z "$(cd "$TMP/prepo" && SSL_CERT_FILE=/x CURL_CA_BUNDLE=/x bash "$BOT" _pushgit t u -c alias.e='!printenv SSL_CERT_FILE CURL_CA_BUNDLE' e)" ]
CRED2=$(cd "$TMP/prepo" && printf 'protocol=https\nhost=evil.example\n\n' | bash "$BOT" _pushgit tok123 u credential fill 2>/dev/null || true)
check "credential 不給 github.com 以外的主機" bash -c "! grep -q tok123 <<<'$CRED2'"
git -C "$TMP/prepo" config push.recurseSubmodules on-demand
check "push.recurseSubmodules 被覆蓋成 no" [ "$(cd "$TMP/prepo" && bash "$BOT" _pushgit t u config push.recurseSubmodules)" = no ]
git -C "$TMP/prepo" config --unset push.recurseSubmodules
git -C "$TMP/prepo" config submodule.lib.url https://github.com/o/lib.git; git -C "$TMP/prepo" config submodule.lib.active true
git -C "$TMP/prepo" config http.postBuffer 524288000
check "http.postBuffer 不擋推送" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u status >/dev/null 2>&1"
git -C "$TMP/prepo" config --unset http.postBuffer
check "已初始化的 submodule 不擋推送" bash -c "cd '$TMP/prepo' && bash '$BOT' _pushgit t u status >/dev/null 2>&1"
git -C "$TMP/prepo" config --remove-section submodule.lib
git -C "$TMP/prepo" config include.path "$TMP/unreadable.cfg"; printf '[url "x"]\n\tinsteadOf = y\n' > "$TMP/unreadable.cfg"; chmod 000 "$TMP/unreadable.cfg"
check "設定檢查失敗時拒絕(fail closed)" bash -c "cd '$TMP/prepo' && ! bash '$BOT' _pushgit t u status >/dev/null 2>&1"
chmod 600 "$TMP/unreadable.cfg"; git -C "$TMP/prepo" config --unset include.path
check "GIT_SSL_NO_VERIFY 被移除" [ -z "$(cd "$TMP/prepo" && GIT_SSL_NO_VERIFY=1 bash "$BOT" _pushgit t u -c alias.e='!printenv GIT_SSL_NO_VERIFY' e)" ]
check "強制 sslVerify" [ "$(cd "$TMP/prepo" && bash "$BOT" _pushgit t u config http.sslVerify)" = true ]

# --- 模式選擇:環境變數蓋過設定檔 ---
check "env TOKEN_FILE 蓋過設定檔 GH_USER" [ "$(env GITHUB_BOT_CONFIG="$TMP/config-gh0" GITHUB_BOT_TOKEN_FILE="$TMP/pat0" bash "$BOT" --repo o/r token)" = ghp_testpat ]

check "default_branch 缺失時拒推" bash -c "GITHUB_BOT_TOKEN_FILE='$TMP/pat0' bash '$BOT' --repo o/nodef push develop 2>&1 | grep -q '缺 .default_branch'"

# --- commit 以 bot 身分 ---
git init -q "$TMP/repo" && (
  cd "$TMP/repo" && echo hi > a && git add a &&
  bash "$BOT" --repo o/r commit -q -m test
) >/dev/null 2>&1
check "commit 作者是 bot" [ "$(git -C "$TMP/repo" log -1 --format='%an <%ae>|%cn')" = 'xhe-bot[bot] <12345+xhe-bot[bot]@users.noreply.github.com>|xhe-bot[bot]' ]

# --- PAT 模式(機器人帳號)---
printf 'ghp_testpat\n' > "$TMP/pat"; chmod 600 "$TMP/pat"
printf 'TOKEN_FILE=%s\n' "$TMP/pat" > "$TMP/config-pat"
PAT_ENV="GITHUB_BOT_CONFIG=$TMP/config-pat"
check "pat token" [ "$(env "$PAT_ENV" bash "$BOT" --repo o/r token)" = ghp_testpat ]
ID=$(env "$PAT_ENV" bash "$BOT" identity)
check "pat identity name"  grep -qx 'name=xhe-bot' <<<"$ID"
check "pat identity email" grep -qx 'email=777+xhe-bot@users.noreply.github.com' <<<"$ID"
check "pat pr 回傳網址" [ "$(env "$PAT_ENV" bash "$BOT" --repo o/r pr --head feat/x --title T)" = https://github.com/o/r/pull/7 ]
check "pat push 預設分支拒絕" bash -c "env '$PAT_ENV' bash '$BOT' --repo o/r push develop 2>&1 | grep -q '不推預設分支'"
check "env TOKEN_FILE 展開 ~" bash -c "HOME='$TMP' GITHUB_BOT_TOKEN_FILE='~/pat0' bash '$BOT' --repo o/r token | grep -qx ghp_testpat"
printf '# 2027 到期\nghp_testpat\n# note\n' > "$TMP/pat-multi"
check "token 檔多行只取第一個 token" bash -c "GITHUB_BOT_TOKEN_FILE='$TMP/pat-multi' bash '$BOT' --repo o/r token | grep -qx ghp_testpat"
check "pat 讀不到檔案失敗" bash -c "! GITHUB_BOT_TOKEN_FILE=/nonexistent bash '$BOT' --repo o/r token 2>/dev/null"
git init -q "$TMP/repo2" && (
  cd "$TMP/repo2" && echo hi > a && git add a &&
  env "$PAT_ENV" bash "$BOT" commit -q -m test
) >/dev/null 2>&1
(cd "$TMP/repo2" && GIT_AUTHOR_NAME=Alice GIT_AUTHOR_EMAIL=a@x GIT_COMMITTER_NAME=Alice GIT_COMMITTER_EMAIL=a@x \
   env "$PAT_ENV" bash "$BOT" commit -q --allow-empty -m env) >/dev/null 2>&1
check "GIT_AUTHOR_* 環境變數蓋不過 bot" [ "$(git -C "$TMP/repo2" log -1 --format='%an|%cn')" = 'xhe-bot|xhe-bot' ]
git -C "$TMP/repo2" reset -q --hard HEAD~1 2>/dev/null
check "pat commit 作者是機器人帳號" [ "$(git -C "$TMP/repo2" log -1 --format='%an <%ae>')" = 'xhe-bot <777+xhe-bot@users.noreply.github.com>' ]

# --- gh 模式(token 從 gh auth token --user 取)---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
[[ "$*" == "auth token --help" ]] && { echo "  -u, --user string"; exit 0; }
[[ "$*" == "auth token --hostname github.com --user xhe-bot" ]] && { echo ghp_testpat; exit 0; }
echo "no account" >&2; exit 1
GH
chmod +x "$TMP/bin/gh"
printf 'GH_USER=xhe-bot\n' > "$TMP/config-gh"
GH_RUN="env PATH=$TMP/bin:$PATH GITHUB_BOT_CONFIG=$TMP/config-gh"
check "gh token" [ "$($GH_RUN bash "$BOT" --repo o/r token)" = ghp_testpat ]
check "gh identity" grep -qx 'name=xhe-bot' <<<"$($GH_RUN bash "$BOT" identity)"
mkdir -p "$TMP/oldgh"; printf '#!/bin/sh\necho "usage: gh auth token [--hostname]"\n' > "$TMP/oldgh/gh"; chmod +x "$TMP/oldgh/gh"
mkdir -p "$TMP/biggh"; printf '#!/bin/bash\nif [ "$*" = "auth token --help" ]; then echo "  -u, --user string"; for i in $(seq 5000); do echo "padding line $i"; done; exit 0; fi\n[ "$*" = "auth token --hostname github.com --user xhe-bot" ] && { echo ghp_testpat; exit 0; }\nexit 1\n' > "$TMP/biggh/gh"; chmod +x "$TMP/biggh/gh"
ok_all=1; for _ in 1 2 3 4 5; do [ "$(PATH="$TMP/biggh:$PATH" GITHUB_BOT_GH_USER=xhe-bot GITHUB_BOT_CONFIG=/nonexistent bash "$BOT" --repo o/r token 2>/dev/null)" = ghp_testpat ] || ok_all=0; done
check "gh --help 很長也不會 SIGPIPE 誤判" [ $ok_all -eq 1 ]
check "舊版 gh 明確提示升級" bash -c "PATH='$TMP/oldgh:$PATH' GITHUB_BOT_GH_USER=xhe-bot GITHUB_BOT_CONFIG=/nonexistent bash '$BOT' --repo o/r token 2>&1 | grep -q '版本太舊'"
check "gh 帳號未登入失敗" bash -c "! env PATH='$TMP/bin:$PATH' GITHUB_BOT_GH_USER=nobody GITHUB_BOT_CONFIG=/nonexistent bash '$BOT' --repo o/r token 2>/dev/null"
check "gh 優先於 TOKEN_FILE" [ "$(env PATH="$TMP/bin:$PATH" GITHUB_BOT_CONFIG="$TMP/config-pat" GITHUB_BOT_GH_USER=xhe-bot bash "$BOT" --repo o/r token)" = ghp_testpat ]

echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
