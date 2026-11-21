#!/usr/bin/env bash
# GitHub App 機器人:用 App 的短效 installation token 以 bot 身分 commit、push 分支、開 PR。
#   bot.sh identity                         印出 bot 的 git name / email
#   bot.sh token                            印出 installation token(給 GH_TOKEN 用,1 小時有效)
#   bot.sh commit <git commit 參數...>      以 bot 身分 git commit
#   bot.sh push <分支>                      把 HEAD 推到遠端 <分支>(拒絕預設分支、main、master,不 force)
#   bot.sh pr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]
# 共用選項(放在子指令前):--repo owner/repo(預設取 origin)
# 設定:~/.config/github-bot/config(或 GITHUB_BOT_CONFIG),二選一:
#   App 模式:APP_ID=、KEY_FILE=(環境變數 GITHUB_BOT_APP_ID、GITHUB_BOT_KEY_FILE 可覆蓋)
#   機器人帳號模式:GH_USER=<帳號>(token 從 gh 的鑰匙圈取:gh auth token --user;最優先)
#                  或 TOKEN_FILE=<檔>(環境變數 GITHUB_BOT_GH_USER、GITHUB_BOT_TOKEN_FILE 可覆蓋)
set -euo pipefail

API=${GITHUB_API_URL:-https://api.github.com}
CONF=${GITHUB_BOT_CONFIG:-$HOME/.config/github-bot/config}
REPO=""

die() { echo "bot.sh: $*" >&2; exit 1; }

load_conf() {
  APP_ID=${GITHUB_BOT_APP_ID:-}
  KEY_FILE=${GITHUB_BOT_KEY_FILE:-}
  TOKEN_FILE=${GITHUB_BOT_TOKEN_FILE:-}
  GH_USER=${GITHUB_BOT_GH_USER:-}
  if [[ -f $CONF ]]; then
    local k v
    while IFS='=' read -r k v; do
      v=${v%$'\r'}
      case $k in
        APP_ID)     [[ -n $APP_ID ]]     || APP_ID=$v ;;
        KEY_FILE)   [[ -n $KEY_FILE ]]   || KEY_FILE=${v/#\~/$HOME} ;;
        TOKEN_FILE) [[ -n $TOKEN_FILE ]] || TOKEN_FILE=${v/#\~/$HOME} ;;
        GH_USER)    [[ -n $GH_USER ]]    || GH_USER=$v ;;
      esac
    done < <(grep -E '^(APP_ID|KEY_FILE|TOKEN_FILE|GH_USER)=' "$CONF" || true)
  fi
  if [[ -n $GH_USER ]]; then
    [[ $GH_USER =~ ^[A-Za-z0-9-]+$ ]] || die "GH_USER 格式錯誤:$GH_USER"
    command -v gh >/dev/null || die "找不到 gh"
    MODE=pat
    return
  fi
  if [[ -n $TOKEN_FILE ]]; then
    MODE=pat
    [[ -r $TOKEN_FILE ]] || die "讀不到 TOKEN_FILE='$TOKEN_FILE'"
    return
  fi
  MODE=app
  [[ $APP_ID =~ ^[0-9]+$ ]] || die "缺 APP_ID(寫在 $CONF 或設 GITHUB_BOT_APP_ID)"
  [[ -r $KEY_FILE ]] || die "讀不到私鑰 KEY_FILE='$KEY_FILE'"
}

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

jwt() {
  local now h p s
  now=$(date +%s)
  h=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
  p=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' $((now - 60)) $((now + 540)) "$APP_ID" | b64url)
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$KEY_FILE" -binary | b64url)
  printf '%s.%s.%s' "$h" "$p" "$s"
}

# api <METHOD> <path> <bearer> [json body]  —— token 經 stdin 給 curl,不出現在 ps
api() {
  local method=$1 path=$2 bearer=$3 body=${4:-} out code
  local -a data=()
  [[ -z $body ]] || data=(-H 'Content-Type: application/json' --data-binary "$body")
  out=$(mktemp)
  code=$(
    {
      printf 'header = "Authorization: Bearer %s"\n' "$bearer"
      printf 'header = "Accept: application/vnd.github+json"\n'
      printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
    } | curl -sS -K - -X "$method" -o "$out" -w '%{http_code}' \
          ${data[@]+"${data[@]}"} "$API$path"
  ) || { rm -f "$out"; die "連不到 $API$path"; }
  if [[ $code != 2* ]]; then
    echo "bot.sh: $method $path → HTTP $code" >&2
    jq -r '.message // empty, (.errors[]? | tostring)' "$out" >&2 2>/dev/null || cat "$out" >&2
    rm -f "$out"; exit 1
  fi
  cat "$out"; rm -f "$out"
}

# 把 GitHub 遠端網址轉成 owner/repo
parse_repo() {
  local url=$1
  [[ $url =~ github\.com[:/]([^/]+)/([^/]+)$ ]] || return 1
  printf '%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]%.git}"
}

resolve_repo() {
  [[ -n $REPO ]] && return
  local url; url=$(git remote get-url origin 2>/dev/null) || die "沒有 origin,請用 --repo owner/repo"
  REPO=$(parse_repo "$url") || die "origin 不是 GitHub 網址:$url"
}

pat() {
  local t
  if [[ -n $GH_USER ]]; then
    t=$(gh auth token --hostname github.com --user "$GH_USER" 2>/dev/null) \
      || die "gh 沒有登入 $GH_USER(執行 gh auth login 加入該帳號)"
  else
    t=$(tr -d ' \t\r\n' < "$TOKEN_FILE")
  fi
  [[ -n $t ]] || die "取不到機器人帳號的 token"
  printf '%s' "$t"
}

token() {
  load_conf
  [[ $MODE == pat ]] && { pat; return; }
  resolve_repo
  local j inst
  j=$(jwt)
  inst=$(api GET "/repos/$REPO/installation" "$j" | jq -r .id) \
    || die "App 沒有安裝在 $REPO(到 App 設定頁 Install App)"
  api POST "/app/installations/$inst/access_tokens" "$j" \
    "$(jq -nc --arg r "${REPO#*/}" '{repositories:[$r]}')" | jq -r .token
}

identity() {
  load_conf
  if [[ $MODE == pat ]]; then
    local u login uid
    u=$(api GET /user "$(pat)")
    login=$(jq -r .login <<<"$u"); uid=$(jq -r .id <<<"$u")
    [[ $uid =~ ^[0-9]+$ && -n $login ]] || die "PAT 查不到帳號資料"
    BOT_NAME=$login
    BOT_EMAIL="${uid}+${login}@users.noreply.github.com"
    return
  fi
  local slug uid
  slug=$(api GET /app "$(jwt)" | jq -r .slug)
  uid=$(curl -sS -H 'Accept: application/vnd.github+json' "$API/users/${slug}%5Bbot%5D" | jq -r .id)
  [[ $uid =~ ^[0-9]+$ ]] || die "查不到 ${slug}[bot] 的 user id"
  BOT_NAME="${slug}[bot]"
  BOT_EMAIL="${uid}+${slug}[bot]@users.noreply.github.com"
}

cmd_commit() {
  identity
  git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" commit "$@"
}

cmd_push() {
  local branch=${1:-}; [[ -n $branch && $# -eq 1 ]] || die "用法:bot.sh push <分支>"
  [[ $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != -* ]] || die "分支名稱不合法:$branch"
  case $branch in main|master) die "不推 $branch;請推功能分支再開 PR" ;; esac
  load_conf; resolve_repo
  BOT_TOKEN=$(token); export BOT_TOKEN
  BOT_USER=x-access-token
  [[ $MODE == pat ]] && { identity; BOT_USER=$BOT_NAME; }
  export BOT_USER
  local def
  def=$(api GET "/repos/$REPO" "$BOT_TOKEN" | jq -r .default_branch)
  [[ $branch != "$def" ]] || die "不推預設分支 $def;請推功能分支再開 PR"
  # credential.helper= 先清掉 osxkeychain 等既有 helper,token 只經環境變數傳遞
  git -c credential.helper= \
      -c 'credential.helper=!f() { echo "username=$BOT_USER"; echo "password=$BOT_TOKEN"; }; f' \
      push "https://github.com/$REPO.git" "HEAD:refs/heads/$branch"
}

cmd_pr() {
  local head="" base="" title="" body=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --head) head=$2; shift 2 ;;
      --base) base=$2; shift 2 ;;
      --title) title=$2; shift 2 ;;
      --body-file) [[ -r $2 ]] || die "讀不到 $2"; body=$(cat "$2"); shift 2 ;;
      *) die "pr 不認得參數 $1" ;;
    esac
  done
  [[ -n $head && -n $title ]] || die "用法:bot.sh pr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]"
  resolve_repo
  local t; t=$(token)
  [[ -n $base ]] || base=$(api GET "/repos/$REPO" "$t" | jq -r .default_branch)
  api POST "/repos/$REPO/pulls" "$t" \
    "$(jq -nc --arg h "$head" --arg b "$base" --arg t "$title" --arg d "$body" \
        '{head:$h, base:$b, title:$t, body:$d}')" | jq -r .html_url
}

[[ ${1:-} == --repo ]] && { REPO=${2:?--repo 要 owner/repo}; shift 2; }
[[ -z $REPO || $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo 格式錯誤:$REPO"

case ${1:-} in
  identity) identity; printf 'name=%s\nemail=%s\n' "$BOT_NAME" "$BOT_EMAIL" ;;
  token)    token ;;
  commit)   shift; cmd_commit "$@" ;;
  push)     shift; cmd_push "$@" ;;
  pr)       shift; cmd_pr "$@" ;;
  _jwt)     load_conf; jwt ;;                         # 測試用
  _parse)   parse_repo "$2" ;;                         # 測試用
  *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
