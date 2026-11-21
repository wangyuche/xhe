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
unset GITHUB_BOT_APP_ID GITHUB_BOT_KEY_FILE

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
check "--repo 格式錯誤拒絕" bash -c "! bash '$BOT' --repo 'bad repo' token 2>/dev/null"

# --- 假 API ---
python3 -I "$HERE/mock_api.py" "$TMP/port" & MOCK_PID=$!
for _ in $(seq 50); do [[ -s $TMP/port ]] && break; sleep 0.1; done
export GITHUB_API_URL="http://127.0.0.1:$(cat "$TMP/port")"

check "token" [ "$(bash "$BOT" --repo o/r token)" = ghs_testtoken ]
check "App 未安裝時失敗" bash -c "! bash '$BOT' --repo o/missing token 2>/dev/null"
ID=$(bash "$BOT" identity)
check "identity name"  grep -qx 'name=xhe-bot\[bot\]' <<<"$ID"
check "identity email" grep -qx 'email=12345+xhe-bot\[bot\]@users.noreply.github.com' <<<"$ID"

printf 'PR 內容\n第二行\n' > "$TMP/body.md"
check "pr 回傳網址" [ "$(bash "$BOT" --repo o/r pr --head feat/x --title 'T "q"' --body-file "$TMP/body.md")" = https://github.com/o/r/pull/7 ]
check "pr 缺 title 失敗" bash -c "! bash '$BOT' --repo o/r pr --head feat/x 2>/dev/null"

check "push main 拒絕"   bash -c "! bash '$BOT' --repo o/r push main 2>/dev/null"
check "push master 拒絕" bash -c "! bash '$BOT' --repo o/r push master 2>/dev/null"
check "push 預設分支拒絕" bash -c "bash '$BOT' --repo o/r push develop 2>&1 | grep -q '不推預設分支'"
check "push 選項式分支名拒絕" bash -c "! bash '$BOT' --repo o/r push --force 2>/dev/null"

# --- commit 以 bot 身分 ---
git init -q "$TMP/repo" && (
  cd "$TMP/repo" && echo hi > a && git add a &&
  bash "$BOT" commit -q -m test
) >/dev/null 2>&1
check "commit 作者是 bot" [ "$(git -C "$TMP/repo" log -1 --format='%an <%ae>|%cn')" = 'xhe-bot[bot] <12345+xhe-bot[bot]@users.noreply.github.com>|xhe-bot[bot]' ]

echo "---- $pass passed, $fail failed"
[[ $fail -eq 0 ]]
