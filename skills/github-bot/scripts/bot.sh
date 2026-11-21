#!/usr/bin/env bash
# GitHub App 機器人:用 App 的短效 installation token 以 bot 身分 commit、push 分支、開 PR。
#   bot.sh identity                         印出 bot 的 git name / email
#   bot.sh token                            印出 installation token(給 GH_TOKEN 用,1 小時有效)
#   bot.sh commit <git commit 參數...>      以 bot 身分 git commit
#   bot.sh push <分支>                      把 HEAD 推到遠端 <分支>(拒絕預設分支、main、master,不 force)
#   bot.sh pr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]
#   bot.sh merge <PR 號碼> --sha <review 過的 head SHA> [--method merge|squash|rebase]
#                                           SHA 不符(review 後又有新 commit)GitHub 會拒絕
# 共用選項(放在子指令前):--repo owner/repo(預設取 origin)
# 設定:~/.config/github-bot/config(或 GITHUB_BOT_CONFIG),三擇一,優先序 GH_USER > TOKEN_FILE > App:
#   GH_USER=<機器人帳號>   token 從 gh 鑰匙圈取(gh auth token --user)
#   TOKEN_FILE=<檔>         機器人帳號的 classic PAT 檔
#   APP_ID=、KEY_FILE=      GitHub App
# 環境變數 GITHUB_BOT_GH_USER / GITHUB_BOT_TOKEN_FILE / GITHUB_BOT_APP_ID(+GITHUB_BOT_KEY_FILE)
# 有設的話直接決定模式,蓋過設定檔。只支援 github.com(GITHUB_BOT_API_URL 僅供測試)。
set -euo pipefail

API=${GITHUB_BOT_API_URL:-https://api.github.com}
CONF=${GITHUB_BOT_CONFIG:-$HOME/.config/github-bot/config}
REPO=""

die() { echo "bot.sh: $*" >&2; exit 1; }
need_val() { [[ $2 -ge 2 ]] || die "$1 後面要接值"; }   # need_val <旗標> <剩餘參數數>

# 去掉前後空白與成對引號:  "~/x"  →  ~/x
trim_val() {
  local v=$1
  v=${v%$'\r'}
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ $v == \"*\" || $v == \'*\' ]] && v=${v:1:${#v}-2}
  printf '%s' "$v"
}

load_conf() {
  local c_app="" c_key="" c_tok="" c_gh="" k v
  if [[ -f $CONF ]]; then
    while IFS='=' read -r k v; do
      k=$(trim_val "$k"); v=$(trim_val "$v")
      case $k in
        APP_ID)     c_app=$v ;;
        KEY_FILE)   c_key=${v/#\~/$HOME} ;;
        TOKEN_FILE) c_tok=${v/#\~/$HOME} ;;
        GH_USER)    c_gh=$v ;;
      esac
    done < <(grep -E '^[[:space:]]*(APP_ID|KEY_FILE|TOKEN_FILE|GH_USER)[[:space:]]*=' "$CONF" || true)
  fi
  GH_USER="" TOKEN_FILE="" APP_ID="" KEY_FILE=""
  if   [[ -n ${GITHUB_BOT_GH_USER:-} ]];    then GH_USER=$GITHUB_BOT_GH_USER
  elif [[ -n ${GITHUB_BOT_TOKEN_FILE:-} ]]; then TOKEN_FILE=$GITHUB_BOT_TOKEN_FILE
  elif [[ -n ${GITHUB_BOT_APP_ID:-} ]];     then APP_ID=$GITHUB_BOT_APP_ID; KEY_FILE=${GITHUB_BOT_KEY_FILE:-$c_key}
  elif [[ -n $c_gh ]];  then GH_USER=$c_gh
  elif [[ -n $c_tok ]]; then TOKEN_FILE=$c_tok
  else APP_ID=$c_app; KEY_FILE=${GITHUB_BOT_KEY_FILE:-$c_key}
  fi
  if [[ -n $GH_USER ]]; then
    [[ $GH_USER =~ ^[A-Za-z0-9-]+$ ]] || die "GH_USER 格式錯誤:$GH_USER"
    command -v gh >/dev/null || die "找不到 gh"
    MODE=pat; return
  fi
  if [[ -n $TOKEN_FILE ]]; then
    [[ -r $TOKEN_FILE ]] || die "讀不到 TOKEN_FILE='$TOKEN_FILE'"
    MODE=pat; return
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

# api <METHOD> <path> <bearer> [json body]  —— token 經 stdin 給 curl,不出現在 ps;
# 回應不落地(不寫暫存檔),中斷也不會留下含 token 的檔案
api() {
  local method=$1 path=$2 bearer=$3 body=${4:-} resp code
  [[ -n $bearer ]] || die "內部錯誤:$method $path 沒有 token"
  local -a data=()
  [[ -z $body ]] || data=(-H 'Content-Type: application/json' --data-binary "$body")
  resp=$(
    {
      printf 'header = "Authorization: Bearer %s"\n' "$bearer"
      printf 'header = "Accept: application/vnd.github+json"\n'
      printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
    } | curl -sS -K - -X "$method" -w '\n%{http_code}' \
          ${data[@]+"${data[@]}"} "$API$path"
  ) || die "連不到 $API$path"
  code=${resp##*$'\n'}; resp=${resp%$'\n'*}
  if [[ $code != 2* ]]; then
    echo "bot.sh: $method $path → HTTP $code" >&2
    jq -r '.message // empty, (.errors[]? | tostring)' <<<"$resp" >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    exit 1
  fi
  printf '%s\n' "$resp"
}

# jfield <欄位> <json>:欄位缺或為 null 就失敗(避免 "null" 字串混過檢查)
jfield() { jq -er "$1 // empty" <<<"$2" || die "API 回應缺 $1"; }

# 把 GitHub 遠端網址轉成 owner/repo
parse_repo() {
  local url=${1%/}
  [[ $url =~ ^(https://([^@/]+@)?|ssh://([^@/]+@)?|[^@/:]+@)(ssh\.)?github\.com(:[0-9]+)?[:/]([^/]+)/([^/]+)$ ]] || return 1
  local r="${BASH_REMATCH[6]}/${BASH_REMATCH[7]%.git}"
  [[ $r =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  printf '%s' "$r"
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
  inst=$(api GET "/repos/$REPO/installation" "$j") \
    || die "App 沒有安裝在 $REPO(到 App 設定頁 Install App)"
  inst=$(jfield .id "$inst")
  local r
  r=$(api POST "/app/installations/$inst/access_tokens" "$j" \
    "$(jq -nc --arg r "${REPO#*/}" '{repositories:[$r]}')")
  jfield .token "$r"
}

identity() {
  load_conf
  if [[ $MODE == pat ]]; then
    local u login uid p
    p=$(pat)
    u=$(api GET /user "$p")
    login=$(jfield .login "$u"); uid=$(jfield .id "$u")
    [[ $uid =~ ^[0-9]+$ && -n $login ]] || die "PAT 查不到帳號資料"
    BOT_NAME=$login
    BOT_EMAIL="${uid}+${login}@users.noreply.github.com"
    return
  fi
  local slug uid j t
  j=$(jwt); t=$(token)
  slug=$(jfield .slug "$(api GET /app "$j")")
  uid=$(jfield .id "$(api GET "/users/${slug}%5Bbot%5D" "$t")")
  [[ $uid =~ ^[0-9]+$ ]] || die "查不到 ${slug}[bot] 的 user id"
  BOT_NAME="${slug}[bot]"
  BOT_EMAIL="${uid}+${slug}[bot]@users.noreply.github.com"
}

cmd_commit() {
  identity
  # GIT_AUTHOR_* / GIT_COMMITTER_* 會蓋過 -c user.*,四個都明確設成 bot
  GIT_AUTHOR_NAME=$BOT_NAME GIT_AUTHOR_EMAIL=$BOT_EMAIL \
  GIT_COMMITTER_NAME=$BOT_NAME GIT_COMMITTER_EMAIL=$BOT_EMAIL \
    git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" commit "$@"
}

# 把 token 寫進 0600 暫存檔(TOKEN_TMP,全域變數,讓 EXIT trap 在函式外也看得到),結束時刪除
TOKEN_TMP=""
token_file() {
  TOKEN_TMP=$(umask 077; mktemp)
  trap '[[ -z $TOKEN_TMP ]] || rm -f "$TOKEN_TMP"' EXIT
  printf '%s' "$1" > "$TOKEN_TMP"
}

# 推送專用的 git 參數:不讀全域 / 系統設定(避免 insteadOf 改走 SSH 或個人憑證)、
# 停用 hooks、token 只放在 0600 暫存檔由 credential helper 讀,不放進子程序的環境變數。
# 用法:push_git <token 檔> <使用者> <git 子指令...>
push_git() {
  local tf=$1 user=$2 bad; shift 2
  # 跟真正推送同一組環境檢查(含 include / includeIf、GIT_CONFIG_COUNT 等環境注入)
  bad=$(env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        git config --includes --name-only --get-regexp '^(url\..*|http\..*extraheader)$' 2>/dev/null || true)
  [[ -z $bad ]] || die "repo 設定有會改寫推送網址或附加認證的項目,請先移除:$(tr '\n' ' ' <<<"$bad")"
  env -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
  git -c credential.helper= \
      -c "credential.helper=!f() { echo username=$user; printf 'password=%s\n' \"\$(cat '$tf')\"; }; f" \
      -c core.hooksPath=/dev/null \
      -c http.extraHeader= \
      -c user.name=bot -c user.email=bot@invalid \
      "$@"
}

cmd_push() {
  local branch=${1:-}; [[ -n $branch && $# -eq 1 ]] || die "用法:bot.sh push <分支>"
  [[ $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != -* ]] || die "分支名稱不合法:$branch"
  case $branch in main|master) die "不推 $branch;請推功能分支再開 PR" ;; esac
  load_conf; resolve_repo
  local t user=x-access-token def
  t=$(token)
  [[ $MODE == pat ]] && { identity; user=$BOT_NAME; }
  def=$(jfield .default_branch "$(api GET "/repos/$REPO" "$t")")
  [[ $branch != "$def" ]] || die "不推預設分支 $def;請推功能分支再開 PR"
  token_file "$t"; unset t
  push_git "$TOKEN_TMP" "$user" push "https://github.com/$REPO.git" "HEAD:refs/heads/$branch"
}

cmd_pr() {
  local head="" base="" title="" body=""
  while [[ $# -gt 0 ]]; do
    case $1 in
      --head) need_val "$1" $#; head=$2; shift 2 ;;
      --base) need_val "$1" $#; base=$2; shift 2 ;;
      --title) need_val "$1" $#; title=$2; shift 2 ;;
      --body-file) need_val "$1" $#; [[ -r $2 ]] || die "讀不到 $2"; body=$(cat "$2"); shift 2 ;;
      *) die "pr 不認得參數 $1" ;;
    esac
  done
  [[ -n $head && -n $title ]] || die "用法:bot.sh pr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]"
  resolve_repo
  local t; t=$(token)
  [[ -n $base ]] || base=$(jfield .default_branch "$(api GET "/repos/$REPO" "$t")")
  local r
  r=$(api POST "/repos/$REPO/pulls" "$t" \
    "$(jq -nc --arg h "$head" --arg b "$base" --arg t "$title" --arg d "$body" \
        '{head:$h, base:$b, title:$t, body:$d}')")
  jfield .html_url "$r"
}

cmd_merge() {
  local num=${1:-} sha="" method=merge
  [[ $num =~ ^[0-9]+$ ]] || die "用法:bot.sh merge <PR 號碼> --sha <SHA> [--method merge|squash|rebase]"
  shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --sha) need_val "$1" $#; sha=$2; shift 2 ;;
      --method) need_val "$1" $#; method=$2; shift 2 ;;
      *) die "merge 不認得參數 $1" ;;
    esac
  done
  [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "--sha 要完整 40 碼 SHA(review 過的 PR head)"
  case $method in merge|squash|rebase) ;; *) die "--method 只能是 merge / squash / rebase" ;; esac
  resolve_repo
  local t pr i st
  t=$(token)
  pr=$(api GET "/repos/$REPO/pulls/$num" "$t")
  [[ $(jq -r .state <<<"$pr") == open ]] || die "PR #$num 不是 open"
  [[ $(jq -r .head.sha <<<"$pr") == "$sha" ]] || die "PR #$num head 已不是 $sha(review 後有新 commit,請重新 review)"
  for i in 1 2 3 4 5 6 7 8 9 10; do        # 剛開 PR 或剛推時 GitHub 還在算,mergeable_state 為 unknown
    st=$(jq -r '.mergeable_state // "unknown"' <<<"$pr")
    [[ $st != unknown ]] && break
    sleep 2
    pr=$(api GET "/repos/$REPO/pulls/$num" "$t")
  done
  case $st in
    clean|has_hooks) ;;
    dirty)    die "PR #$num 有衝突,無法合併" ;;
    unstable) die "PR #$num 有失敗或未完成的檢查,不合併" ;;
    blocked)  die "PR #$num 被分支規則擋住(需要 approval 或必要檢查),不合併" ;;
    behind)   die "PR #$num 落後 base,分支規則要求先更新" ;;
    *)        die "PR #$num 狀態不允許合併(mergeable_state=$st)" ;;
  esac
  local r
  r=$(api PUT "/repos/$REPO/pulls/$num/merge" "$t" \
    "$(jq -nc --arg s "$sha" --arg m "$method" '{sha:$s, merge_method:$m}')")
  jfield .sha "$r"
}

[[ ${1:-} == --repo ]] && { need_val --repo $#; REPO=$2; shift 2; }
[[ -z $REPO || $REPO =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || die "--repo 格式錯誤:$REPO"

case ${1:-} in
  identity) identity; printf 'name=%s\nemail=%s\n' "$BOT_NAME" "$BOT_EMAIL" ;;
  token)    token ;;
  commit)   shift; cmd_commit "$@" ;;
  push)     shift; cmd_push "$@" ;;
  pr)       shift; cmd_pr "$@" ;;
  merge)    shift; cmd_merge "$@" ;;
  _jwt)     load_conf; jwt ;;                         # 測試用
  _parse)   parse_repo "$2" ;;                         # 測試用
  _pushgit) # 測試用:_pushgit <token> <使用者> <git 子指令...>,用 push 的同一組 git 參數
            token_file "$2"; u=$3; shift 3; push_git "$TOKEN_TMP" "$u" "$@" ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
