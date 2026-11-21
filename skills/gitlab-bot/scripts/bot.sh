#!/usr/bin/env bash
# GitLab(自建或 gitlab.com)機器人:token 從 macOS 鑰匙圈取,commit、push 功能分支、開 MR、review 後合併。
#   bot.sh identity                         印出 token 擁有者與 commit 用的 name / email
#   bot.sh project                          印出專案資訊(id、預設分支、權限、是否有 CI)
#   bot.sh commit <git commit 參數...>      以 token 擁有者身分 git commit
#   bot.sh push <分支>                      把 HEAD 推到遠端 <分支>(拒絕預設分支、main、master,不 force)
#   bot.sh mr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]
#                                           開 MR,印出網址;該分支已有 open MR 就印既有網址
#   bot.sh merge <MR iid> --sha <review 過的 head SHA>
#                                           只合併沒有 CI 的專案 / commit;有 CI 就拒絕
# 多專案:主機與專案路徑一律從 origin 解析(https://host/group/sub/proj.git 或 git@host:group/proj.git),
#   token 在鑰匙圈:service=gitlab-bot、account=<主機>。同一主機所有專案共用一筆。
#   測試用環境變數(只接受本機,避免 token 被送到別處):
#     GITLAB_BOT_TOKEN_CMD  改用其他取 token 的指令
#     GITLAB_BOT_API_URL    http://127.0.0.1:<port> 或 http://localhost:<port>,取代 https://<主機>(API 仍走 /api/v4)
#     GITLAB_BOT_PUSH_URL   本機絕對路徑或 file:///...,push 改推到這裡(例如本機 bare repo)
# identity / project 會檢查 token scope(GET /personal_access_tokens/self):缺 api 或 write_repository 時結束碼 3。
set -euo pipefail

die() { echo "bot.sh: $*" >&2; exit 1; }
SCRATCH=$(umask 077; mktemp -d "${TMPDIR:-/tmp}/gitlab-bot.XXXXXX")
[[ $SCRATCH =~ ^[A-Za-z0-9/._-]+$ ]] || { rm -rf "$SCRATCH"; die "暫存目錄路徑含特殊字元"; }
cleanup() { rm -rf "$SCRATCH"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---- 解析 origin ----
ORIGIN=$(git remote get-url origin 2>/dev/null) || die "目前目錄不是有 origin 的 git repo"
if [[ $ORIGIN =~ ^https://([^/@]+@)?([A-Za-z0-9.-]+)(:[0-9]+)?/(.+)$ ]]; then
  HOST=${BASH_REMATCH[2]}; PORT=${BASH_REMATCH[3]}; PPATH=${BASH_REMATCH[4]}
elif [[ $ORIGIN =~ ^(ssh://)?git@([A-Za-z0-9.-]+)(:[0-9]+)?[:/](.+)$ ]]; then
  HOST=${BASH_REMATCH[2]}; PORT=""; PPATH=${BASH_REMATCH[4]}
else
  die "看不懂 origin 網址:$ORIGIN"
fi
[[ $ORIGIN != https://*@* ]] || die "origin 網址內含帳號或憑證,請改成 https://$HOST/$PPATH"
PPATH=${PPATH%.git}; PPATH=${PPATH%/}
[[ $PPATH =~ ^[A-Za-z0-9._/-]+$ ]] || die "專案路徑含不支援的字元:$PPATH"
BASE="https://$HOST$PORT"
API="$BASE/api/v4"
PID_ENC=$(jq -rn --arg p "$PPATH" '$p|@uri')
PUSH_URL="$BASE/$PPATH.git"
# 測試用覆寫:只能指向本機
if [[ -n ${GITLAB_BOT_API_URL-} ]]; then
  [[ $GITLAB_BOT_API_URL =~ ^http://(127\.0\.0\.1|localhost):[0-9]{1,5}$ ]] \
    || die "GITLAB_BOT_API_URL 只接受 http://127.0.0.1:<port> 或 http://localhost:<port>(測試用)"
  API="$GITLAB_BOT_API_URL/api/v4"
fi
if [[ -n ${GITLAB_BOT_PUSH_URL-} ]]; then
  [[ $GITLAB_BOT_PUSH_URL =~ ^(/|file:///)[^:]*$ ]] \
    || die "GITLAB_BOT_PUSH_URL 只接受本機絕對路徑或 file:///...(測試用)"
  PUSH_URL=$GITLAB_BOT_PUSH_URL
fi

get_token() {
  local t
  if [[ -n ${GITLAB_BOT_TOKEN_CMD-} ]]; then t=$(bash -c "$GITLAB_BOT_TOKEN_CMD")
  else t=$(security find-generic-password -s gitlab-bot -a "$HOST" -w 2>/dev/null) \
    || die "鑰匙圈找不到 $HOST 的 token。請執行:security add-generic-password -s gitlab-bot -a $HOST -w"
  fi
  [[ -n $t && $t =~ ^[A-Za-z0-9._-]+$ ]] || die "token 格式不對"
  printf '%s' "$t"
}
TOKEN=$(get_token)

# api <METHOD> <路徑> [JSON body]:token 經 stdin 傳給 curl,不出現在指令列;失敗印 GitLab 訊息
api() {
  local method=$1 path=$2 body=${3-} out=$SCRATCH/resp code
  local args=(-q -sS -o "$out" -w '%{http_code}' -X "$method" -H @- "$API$path")
  [[ -n $body ]] && args+=(-H 'Content-Type: application/json' --data-binary "$body")
  code=$(printf 'PRIVATE-TOKEN: %s\n' "$TOKEN" | curl "${args[@]}") || die "連不到 $API"
  if [[ $code != 2* ]]; then
    echo "bot.sh: GitLab API $method $path → HTTP $code: $(head -c 500 "$out")" >&2; return 1
  fi
  # GitLab 有時回傳含未跳脫控制字元的 JSON(jq 會拒絕),先以寬鬆模式解析再重新輸出
  [[ -s $out ]] || return 0
  python3 -I -c 'import sys,json;json.dump(json.loads(sys.stdin.buffer.read().decode("utf-8"),strict=False),sys.stdout,ensure_ascii=False)' <"$out"
}

ident() {
  local u; u=$(api GET /user)
  NAME=$(jq -r '.name // .username' <<<"$u")
  EMAIL=$(jq -r '(.commit_email // "") as $c | if $c != "" and $c != "_private" then $c else (.email // "") end' <<<"$u")
  [[ -n $EMAIL ]] || EMAIL="$(jq -r .username <<<"$u")@users.noreply.$HOST"
  USERNAME=$(jq -r .username <<<"$u")
}

project_json() { api GET "/projects/$PID_ENC"; }

# token_scopes:印 token 名稱、scopes、到期日;缺 api / write_repository 時警告並設 SCOPE_RC=3。
# 端點失敗(有些 token 類型不支援)只印「無法確認 scope」,不算失敗。
SCOPE_RC=0
token_scopes() {
  local t missing=() s
  if ! t=$(api GET /personal_access_tokens/self 2>/dev/null) || ! jq -e '.scopes|type=="array"' >/dev/null 2>&1 <<<"$t"; then
    echo "token:          無法確認 scope(/personal_access_tokens/self 查詢失敗,此 token 類型可能不支援)"; return 0
  fi
  jq -r '"token:          \(.name // "(無名稱)")\nscopes:         \(.scopes|join(", "))\nexpires_at:     \(.expires_at // "(無到期日)")"' <<<"$t"
  for s in api write_repository; do
    jq -e --arg s "$s" '.scopes|index($s)' >/dev/null <<<"$t" || missing+=("$s")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "bot.sh: 警告:token 缺少 scope:${missing[*]}。建立 MR 需要 api scope,否則 403 insufficient_scope;push 需要 write_repository。請重新建立含 api + write_repository 的 token。" >&2
    SCOPE_RC=3
  fi
}

# has_ci <ref>:該 ref 有 .gitlab-ci.yml 就印出 yes
# ci_file_at <ref>:有 .gitlab-ci.yml 印 yes;只有 404 才算 no;其他狀態(401、500、連不上)印 error,
# 呼叫端必須當成「無法確認」而拒絕合併(否則查詢失敗時會把有 CI 的專案當成沒有 CI)
ci_file_at() {
  local ref code; ref=$(jq -rn --arg r "$1" '$r|@uri')
  code=$(printf 'PRIVATE-TOKEN: %s\n' "$TOKEN" | curl -q -sS -o /dev/null -w '%{http_code}' -H @- \
    "$API/projects/$PID_ENC/repository/files/.gitlab-ci.yml?ref=$ref" 2>/dev/null) || code=000
  case $code in 2*) echo yes ;; 404) echo no ;; *) echo "bot.sh: 查詢 .gitlab-ci.yml($1)→ HTTP $code" >&2; echo error ;; esac
}

# 推送用的乾淨 git:不讀全域/系統設定、HOME 為空目錄、停用 hooks;token 只在 0600 暫存檔給 credential helper
clean_push() {
  local branch=$1
  # repo 設定裡能改寫網址/認證/TLS 的項目一律拒絕
  local bad
  bad=$(git config --local --includes --get-regexp '^(url\.|credential|core\.sshcommand|http\.)' 2>/dev/null \
        | grep -viE '^http\.(postbuffer|version|lowspeedlimit|lowspeedtime) ' || true)
  [[ -z $bad ]] || die "repo 設定含會影響推送的項目,拒絕推送:
$bad"
  mkdir -p "$SCRATCH/home"
  (umask 077; printf '%s' "$TOKEN" > "$SCRATCH/t")
  local helper="!f(){ test \"\$1\" = get && printf 'username=oauth2\\npassword=%s\\n' \"\$(cat $SCRATCH/t)\"; }; f"
  env -u GIT_CONFIG -u GIT_SSL_NO_VERIFY -u GIT_SSL_CAINFO -u SSL_CERT_FILE -u CURL_CA_BUNDLE \
      -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u GIT_TRACE -u GIT_CURL_VERBOSE \
      HOME="$SCRATCH/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= -c credential.helper="$helper" -c core.hooksPath=/dev/null \
      push "$PUSH_URL" "HEAD:refs/heads/$branch"
  rm -f "$SCRATCH/t"
  git update-ref "refs/remotes/origin/$branch" HEAD 2>/dev/null || true
}

need() { [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 後面要接值"; }

cmd=${1-}; shift || true
case $cmd in
  identity)
    ident; echo "host:     $HOST"; echo "user:     $USERNAME"; echo "name:     $NAME"; echo "email:    $EMAIL"
    token_scopes; exit "$SCOPE_RC" ;;
  project)
    p=$(project_json)
    jq -r '"id:             \(.id)\npath:           \(.path_with_namespace)\ndefault_branch: \(.default_branch)\nweb_url:        \(.web_url)\naccess_level:   \(.permissions.project_access.access_level // .permissions.group_access.access_level)"' <<<"$p"
    echo "gitlab-ci.yml:  $(ci_file_at "$(jq -r .default_branch <<<"$p")") (預設分支)"
    prot=$(api GET "/projects/$PID_ENC/protected_branches" | jq -r '[.[].name]|join(", ")')
    echo "protected:      ${prot:-(無)}"
    token_scopes; exit "$SCOPE_RC" ;;
  commit)
    ident
    git -c user.name="$NAME" -c user.email="$EMAIL" commit "$@" ;;
  push)
    [[ $# -eq 1 ]] || die "用法:bot.sh push <分支>(不支援其他參數,包括 force)"
    br=$1
    git check-ref-format --branch "$br" >/dev/null || die "分支名稱不合法:$br"
    def=$(project_json | jq -r .default_branch)
    case $br in main|master|"$def") die "拒絕直接推 $br(預設/主線分支一律走 MR)" ;; esac
    clean_push "$br" ;;
  mr)
    head="" base="" title="" bodyf=""
    while [[ $# -gt 0 ]]; do
      case $1 in
        --head) need "$@"; head=$2; shift 2 ;;
        --base) need "$@"; base=$2; shift 2 ;;
        --title) need "$@"; title=$2; shift 2 ;;
        --body-file) need "$@"; bodyf=$2; shift 2 ;;
        *) die "不認得的參數:$1" ;;
      esac
    done
    [[ -n $head && -n $title ]] || die "需要 --head 與 --title"
    [[ -n $base ]] || base=$(project_json | jq -r .default_branch)
    hq=$(jq -rn --arg h "$head" '$h|@uri')
    existing=$(api GET "/projects/$PID_ENC/merge_requests?state=opened&source_branch=$hq" | jq -r '.[0].web_url // empty')
    if [[ -n $existing ]]; then echo "$existing"; exit 0; fi
    body=""; [[ -z $bodyf ]] || body=$(cat "$bodyf")
    payload=$(jq -n --arg s "$head" --arg t "$base" --arg ti "$title" --arg d "$body" \
      '{source_branch:$s, target_branch:$t, title:$ti, description:$d, remove_source_branch:false}')
    api POST "/projects/$PID_ENC/merge_requests" "$payload" | jq -r .web_url ;;
  merge)
    iid=${1-}; shift || true
    [[ $iid =~ ^[0-9]+$ ]] || die "用法:bot.sh merge <MR iid> --sha <SHA>"
    sha=""
    while [[ $# -gt 0 ]]; do case $1 in --sha) need "$@"; sha=$2; shift 2 ;; *) die "不認得的參數:$1" ;; esac; done
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "--sha 要完整 40 碼 SHA"
    # GitLab 延遲計算可合併狀態:觸發重新檢查,unchecked / checking 時最多等 60 秒
    for _ in $(seq 1 20); do
      m=$(api GET "/projects/$PID_ENC/merge_requests/$iid?with_merge_status_recheck=true")
      case $(jq -r '.detailed_merge_status // .merge_status' <<<"$m") in
        unchecked|checking|preparing|approvals_syncing) sleep 3 ;;
        *) break ;;
      esac
    done
    [[ $(jq -r .state <<<"$m") == opened ]] || die "MR !$iid 不是 open"
    [[ $(jq -r .sha <<<"$m") == "$sha" ]] || die "MR head 是 $(jq -r .sha <<<"$m"),不是 review 過的 $sha"
    [[ $(jq -r .has_conflicts <<<"$m") == false ]] || die "MR 有衝突"
    src=$(jq -r .source_branch <<<"$m"); tgt=$(jq -r .target_branch <<<"$m")
    found=()
    for r in "$sha" "$tgt"; do
      case $(ci_file_at "$r") in
        no) ;;
        yes) [[ $r == "$sha" ]] && found+=("head 有 .gitlab-ci.yml") || found+=("$tgt 有 .gitlab-ci.yml") ;;
        *) die "無法確認 $r 有沒有 .gitlab-ci.yml,不合併" ;;
      esac
    done
    np=$(api GET "/projects/$PID_ENC/pipelines?sha=$sha" | jq length)
    [[ $np == 0 ]] || found+=("head 有 $np 個 pipeline")
    ns=$(api GET "/projects/$PID_ENC/repository/commits/$sha/statuses" | jq length)
    [[ $ns == 0 ]] || found+=("head 有 $ns 個 commit status")
    if [[ ${#found[@]} -gt 0 ]]; then
      printf 'bot.sh: 偵測到 CI,不自動合併,請使用者確認 CI 後自行合併:\n' >&2; printf '  - %s\n' "${found[@]}" >&2; exit 2
    fi
    st=$(jq -r '.detailed_merge_status // .merge_status' <<<"$m")
    case $st in mergeable|can_be_merged) ;; *) die "GitLab 回報無法合併:$st" ;; esac
    r=$(api PUT "/projects/$PID_ENC/merge_requests/$iid/merge" "$(jq -n --arg s "$sha" '{sha:$s, should_remove_source_branch:false}')")
    jq -r '"merged: \(.web_url)\nmerge_commit_sha: \(.merge_commit_sha // .squash_commit_sha // "(fast-forward)")"' <<<"$r" ;;
  *)
    sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; [[ -z $cmd ]] || exit 1 ;;
esac
