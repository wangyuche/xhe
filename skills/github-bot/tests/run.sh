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
check "pr 缺 title 失敗" bash -c "! bash '$BOT' --repo o/r pr --head feat/x 2>/dev/null"

check "push main 拒絕"   bash -c "! bash '$BOT' --repo o/r push main 2>/dev/null"
check "push master 拒絕" bash -c "! bash '$BOT' --repo o/r push master 2>/dev/null"
check "push 預設分支拒絕" bash -c "bash '$BOT' --repo o/r push develop 2>&1 | grep -q '不推預設分支'"
check "push 選項式分支名拒絕" bash -c "! bash '$BOT' --repo o/r push --force 2>/dev/null"

printf 'GH_USER=xhe-bot\n' > "$TMP/config-gh0"; printf 'ghp_testpat\n' > "$TMP/pat0"
A40=$(printf 'a%.0s' $(seq 40)); B40=$(printf 'b%.0s' $(seq 40)); C40=$(printf 'c%.0s' $(seq 40))
check "merge 回傳 merge commit" [ "$(bash "$BOT" --repo o/r merge 7 --sha "$A40")" = "$B40" ]
check "merge SHA 不符拒絕" bash -c "bash '$BOT' --repo o/r merge 7 --sha $C40 2>&1 | grep -q '重新 review'"
check "merge 缺 --sha 拒絕" bash -c "! bash '$BOT' --repo o/r merge 7 2>/dev/null"
check "merge 短 SHA 拒絕" bash -c "! bash '$BOT' --repo o/r merge 7 --sha abc1234 2>/dev/null"
check "merge 缺值不 crash" bash -c "bash '$BOT' --repo o/r merge 7 --sha 2>&1 | grep -q '後面要接值'"
check "pr 缺值不 crash" bash -c "bash '$BOT' --repo o/r pr --head 2>&1 | grep -q '後面要接值'"
check "merge 檢查失敗拒絕" bash -c "bash '$BOT' --repo o/r merge 9 --sha $A40 2>&1 | grep -q '失敗或未完成的檢查'"
check "merge closed 立即拒絕" bash -c "s=\$(date +%s); bash '$BOT' --repo o/r merge 10 --sha $A40 2>&1 | grep -q '不是 open' && [ \$(( \$(date +%s) - s )) -lt 3 ]"
check "merge 有衝突拒絕" bash -c "bash '$BOT' --repo o/r merge 8 --sha $A40 2>&1 | grep -q '有衝突'"
check "merge 不明 method 拒絕" bash -c "! bash '$BOT' --repo o/r merge 7 --sha $A40 --method octopus 2>/dev/null"

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
check "停用 hooks" [ "$(cd "$TMP/prepo" && bash "$BOT" _pushgit t u config core.hooksPath)" = /dev/null ]
git -C "$TMP/prepo" config url."git@github.com:".insteadOf https://github.com/
git -C "$TMP/prepo" config --unset url."git@github.com:".insteadOf
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
[[ "$*" == "auth token --hostname github.com --user xhe-bot" ]] && { echo ghp_testpat; exit 0; }
echo "no account" >&2; exit 1
GH
chmod +x "$TMP/bin/gh"
printf 'GH_USER=xhe-bot\n' > "$TMP/config-gh"
GH_RUN="env PATH=$TMP/bin:$PATH GITHUB_BOT_CONFIG=$TMP/config-gh"
check "gh token" [ "$($GH_RUN bash "$BOT" --repo o/r token)" = ghp_testpat ]
check "gh identity" grep -qx 'name=xhe-bot' <<<"$($GH_RUN bash "$BOT" identity)"
check "gh 帳號未登入失敗" bash -c "! env PATH='$TMP/bin:$PATH' GITHUB_BOT_GH_USER=nobody GITHUB_BOT_CONFIG=/nonexistent bash '$BOT' --repo o/r token 2>/dev/null"
check "gh 優先於 TOKEN_FILE" [ "$(env PATH="$TMP/bin:$PATH" GITHUB_BOT_CONFIG="$TMP/config-pat" GITHUB_BOT_GH_USER=xhe-bot bash "$BOT" --repo o/r token)" = ghp_testpat ]

echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
