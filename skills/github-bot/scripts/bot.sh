#!/usr/bin/env bash
# GitHub App 機器人:用 App 的短效 installation token 以 bot 身分 commit、push 分支、開 PR。
#   bot.sh identity                         印出 bot 的 git name / email
#   bot.sh token                            印出 installation token(給 GH_TOKEN 用,1 小時有效)
#   bot.sh commit <git commit 參數...>      以 bot 身分 git commit
#   bot.sh push <分支>                      把 HEAD 推到遠端 <分支>(拒絕預設分支、main、master,不 force)
#   bot.sh pr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]
#   bot.sh merge <PR 號碼> --sha <review 過的 head SHA> [--method merge|squash|rebase] [--allow-no-ci]
#                [--ignore-suite <id>]...     略過確定永遠不會跑的 check suite
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
# GITHUB_BOT_API_URL 只給測試用:只接受 api.github.com 或本機,避免 token 被送到別的主機
[[ $API == https://api.github.com || $API =~ ^http://(127\.0\.0\.1|localhost)(:[0-9]+)?$ ]] \
  || { echo "bot.sh: GITHUB_BOT_API_URL 只能是 https://api.github.com 或本機測試位址" >&2; exit 1; }
CONF=${GITHUB_BOT_CONFIG:-$HOME/.config/github-bot/config}
REPO=""

die() { echo "bot.sh: $*" >&2; exit 1; }

# 所有暫存(token 檔、推送用的空 HOME)都在 SCRATCH 底下,結束或被中斷時整個刪掉
SCRATCH=$(umask 077; mktemp -d)
CHILD_PID=""
cleanup() { [[ -z $CHILD_PID ]] || kill "$CHILD_PID" 2>/dev/null; rm -rf "$SCRATCH"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP
need_val() { [[ $2 -ge 2 ]] || die "$1 後面要接值"; }   # need_val <旗標> <剩餘參數數>

# 去掉前後空白與成對引號:  "~/x"  →  ~/x
trim_val() {
  local v=$1
  v=${v%$'\r'}
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ $v == \"*\" || $v == \'*\' ]] && v=${v:1:${#v}-2}
  printf '%s' "$v"
}

# 只展開開頭的 ~/(不支援 ~user)
expand_home() {
  local v=$1
  [[ $v == '~/'* ]] && v=$HOME/${v#'~/'}
  [[ $v == '~' ]] && v=$HOME
  printf '%s' "$v"
}

load_conf() {
  local c_app="" c_key="" c_tok="" c_gh="" k v quoted
  if [[ -f $CONF ]]; then
    local line
    while IFS= read -r line; do
      k=${line%%=*}; v=${line#*=}      # 自己切:bash 3.2 的 IFS='=' read 會吃掉值結尾的 =
      # 行尾註解:加引號的值取到對應的結尾引號為止;未加引號的值砍掉「 # ...」
      if [[ $v =~ ^[[:space:]]*\"([^\"]*)\" ]] || [[ $v =~ ^[[:space:]]*\'([^\']*)\' ]]; then
        v=${BASH_REMATCH[1]}; quoted=1          # 引號內的空白保留
      else
        v=${v%%[[:space:]]#*}; quoted=0
      fi
      k=$(trim_val "$k"); [[ $quoted -eq 1 ]] || v=$(trim_val "$v")
      case $k in
        APP_ID)     c_app=$v ;;
        KEY_FILE)   c_key=$(expand_home "$v") ;;
        TOKEN_FILE) c_tok=$(expand_home "$v") ;;
        GH_USER)    c_gh=$v ;;
      esac
    done < <(grep -E '^[[:space:]]*(APP_ID|KEY_FILE|TOKEN_FILE|GH_USER)[[:space:]]*=' "$CONF" || true)
  fi
  GH_USER="" TOKEN_FILE="" APP_ID="" KEY_FILE=""
  if   [[ -n ${GITHUB_BOT_GH_USER:-} ]];    then GH_USER=$GITHUB_BOT_GH_USER
  elif [[ -n ${GITHUB_BOT_TOKEN_FILE:-} ]]; then TOKEN_FILE=$(expand_home "$GITHUB_BOT_TOKEN_FILE")
  elif [[ -n ${GITHUB_BOT_APP_ID:-} ]];     then APP_ID=$GITHUB_BOT_APP_ID; KEY_FILE=${GITHUB_BOT_KEY_FILE:-$c_key}
  elif [[ -n $c_gh ]];  then GH_USER=$c_gh
  elif [[ -n $c_tok ]]; then TOKEN_FILE=$c_tok
  else APP_ID=$c_app; KEY_FILE=${GITHUB_BOT_KEY_FILE:-$c_key}
  fi
  KEY_FILE=$(expand_home "$KEY_FILE")
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
  s=$(printf '%s.%s' "$h" "$p" | openssl dgst -sha256 -sign "$KEY_FILE" -binary 2>/dev/null | b64url) \
    || die "私鑰簽章失敗(KEY_FILE 壞掉、有密碼或不是 RSA 私鑰)"
  [[ -n $s ]] || die "私鑰簽章失敗(KEY_FILE 壞掉、有密碼或不是 RSA 私鑰)"
  printf '%s.%s.%s' "$h" "$p" "$s"
}

# api <METHOD> <path> <bearer> [json body]  —— token 經 stdin 給 curl,不出現在 ps;
# 回應不落地(不寫暫存檔),中斷也不會留下含 token 的檔案
api() {
  local method=$1 path=$2 bearer=$3 body=${4:-} resp code
  [[ -n $bearer ]] || die "內部錯誤:$method $path 沒有 token"
  local -a data=()
  if [[ -n $body ]]; then                        # 內文寫檔再給 curl:不出現在 ps,也不受 ARG_MAX 限制
    local bf; bf=$(umask 077; mktemp "$SCRATCH/body.XXXXXX")
    printf '%s' "$body" > "$bf"
    data=(-H 'Content-Type: application/json' --data-binary "@$bf")
  fi
  resp=$(
    {
      printf 'header = "Authorization: Bearer %s"\n' "$bearer"
      printf 'header = "Accept: application/vnd.github+json"\n'
      printf 'header = "X-GitHub-Api-Version: 2022-11-28"\n'
    } | curl -q -sS --connect-timeout 10 --max-time 60 -K - -X "$method" -w '\n%{http_code}' \
          ${data[@]+"${data[@]}"} "$API$path"
  ) || die "連不到 $API$path"
  code=${resp##*$'\n'}; resp=${resp%$'\n'*}
  if [[ $code != 2* ]]; then
    echo "bot.sh: $method $path → HTTP $code" >&2
    [[ $code == 301 || $code == 307 ]] && echo "bot.sh: repo 已改名或移轉,請更新 origin 或 --repo" >&2
    jq -r '.message // empty, (.errors[]? | tostring)' <<<"$resp" >&2 2>/dev/null || printf '%s\n' "$resp" >&2
    exit 1
  fi
  printf '%s\n' "$resp"
}

# api_try:同 api,但 HTTP 404 回傳 4(給「可能不存在」的查詢用);其他錯誤回傳 2 並印出原因。
# 呼叫端必須明確檢查回傳碼(在 $(...) 裡 exit 只會結束子 shell)
api_try() {
  local out err="$SCRATCH/api_try.err"
  out=$(api "$@" 2>"$err") && { printf '%s\n' "$out"; return 0; }
  grep -q '→ HTTP 404' "$err" && return 4
  cat "$err" >&2; return 2
}

# jfield <欄位> <json>:欄位缺或為 null 就失敗(避免 "null" 字串混過檢查)
jfield() { jq -er "$1 // empty" <<<"$2" || die "API 回應缺 $1"; }

# owner/repo 格式;不接受 . 或 .. 片段(curl 會把它們折疊成別的 API 路徑)
valid_repo() {
  [[ $1 =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
  local o=${1%%/*} n=${1#*/}
  [[ $o != . && $o != .. && $n != . && $n != .. ]]
}

# 把 GitHub 遠端網址轉成 owner/repo
parse_repo() {
  local url=${1%/}
  [[ $url =~ ^(https://([^@/]+@)?|ssh://([^@/]+@)?|[^@/:]+@)(ssh\.)?github\.com(:[0-9]+)?[:/]([^/]+)/([^/]+)$ ]] || return 1
  local r="${BASH_REMATCH[6]}/${BASH_REMATCH[7]%.git}"
  valid_repo "$r" || return 1
  printf '%s' "$r"
}

resolve_repo() {
  [[ -n $REPO ]] && return
  local url; url=$(git remote get-url origin 2>/dev/null) || die "沒有 origin,請用 --repo owner/repo"
  REPO=$(parse_repo "$url") || die "origin 不是 github.com 網址:$url(SSH host 別名等情況請加 --repo owner/repo)"
}

pat() {
  local t
  if [[ -n $GH_USER ]]; then
    local help; help=$(gh auth token --help 2>/dev/null || true)   # 不用管線:grep -q 提早結束會讓 gh 收到 SIGPIPE
    grep -q -- '--user' <<<"$help" \
      || die "gh 版本太舊,不支援 gh auth token --user(多帳號);請升級 gh"
    t=$(gh auth token --hostname github.com --user "$GH_USER" 2>"$SCRATCH/gh.err") \
      || die "gh 取不到 $GH_USER 的 token(沒登入就執行 gh auth login 加入該帳號):$(cat "$SCRATCH/gh.err")"
  else
    t=$(awk '{ sub(/\r$/, "") } !/^[[:space:]]*(#|$)/ { print $1; exit }' "$TOKEN_FILE")
  fi
  [[ -n $t ]] || die "取不到機器人帳號的 token"
  printf '%s' "$t"
}

token() {
  load_conf
  [[ $MODE == pat ]] && { pat; return; }
  resolve_repo
  local j inst
  j=$(jwt) || exit 1
  inst=$(api GET "/repos/$REPO/installation" "$j") \
    || die "取不到 $REPO 的 App installation(HTTP 404 = App 沒裝在這個 repo,到 App 設定頁 Install App;401 = APP_ID / 私鑰不對或系統時間偏差)"
  inst=$(jfield .id "$inst") || exit 1
  local r
  r=$(api POST "/app/installations/$inst/access_tokens" "$j" \
    "$(jq -nc --arg r "${REPO#*/}" '{repositories:[$r]}')") || exit 1
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
  local slug uid j t="" u
  j=$(jwt) || exit 1
  local app; app=$(api GET /app "$j") || exit 1
  slug=$(jfield .slug "$app")
  # 有 repo(--repo 或 GitHub origin)就用 installation token 查,避免匿名 60 次 / 小時限制;
  # 新 repo 還沒有 origin 時退回匿名查詢
  if [[ -n $REPO ]] || parse_repo "$(git remote get-url origin 2>/dev/null)" >/dev/null; then
    local err
    # App 沒裝在這個 repo(例如 fork,installation 查詢 404)才退回匿名查詢;其他錯誤照實回報
    if ! t=$(token 2>"$SCRATCH/token.err"); then
      err=$(cat "$SCRATCH/token.err")
      grep -q '/installation → HTTP 404' <<<"$err" || { printf '%s\n' "$err" >&2; exit 1; }
      t=""
    fi
  fi
  if [[ -n $t ]]; then
    u=$(api GET "/users/${slug}%5Bbot%5D" "$t")
  else
    u=$(curl -q -sS -f --connect-timeout 10 --max-time 60 -H 'Accept: application/vnd.github+json' "$API/users/${slug}%5Bbot%5D") \
      || die "查不到 ${slug}[bot] 的 user id(匿名查詢失敗,可能是次數限制;加 --repo owner/repo 改用認證查詢)"
  fi
  uid=$(jfield .id "$u")
  [[ $uid =~ ^[0-9]+$ ]] || die "查不到 ${slug}[bot] 的 user id"
  BOT_NAME="${slug}[bot]"
  BOT_EMAIL="${uid}+${slug}[bot]@users.noreply.github.com"
}

cmd_commit() {
  identity
  # GIT_AUTHOR_* / GIT_COMMITTER_* 會蓋過 -c user.*,四個都明確設成 bot
  GIT_AUTHOR_NAME=$BOT_NAME GIT_AUTHOR_EMAIL=$BOT_EMAIL \
  GIT_COMMITTER_NAME=$BOT_NAME GIT_COMMITTER_EMAIL=$BOT_EMAIL \
    git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" -c commit.gpgsign=false commit "$@"
}

# token 暫存檔放在 SCRATCH(0700 暫存目錄)。被中斷(INT / TERM / HUP)也會刪除。
TOKEN_TMP=""
token_file() {
  TOKEN_TMP="$SCRATCH/token"
  (umask 077; printf '%s' "$1" > "$TOKEN_TMP")
}

# 推送專用的 git 參數:不讀全域 / 系統設定(避免 insteadOf 改走 SSH 或個人憑證)、
# 停用 hooks、token 只放在 0600 暫存檔由 credential helper 讀,不放進子程序的環境變數。
# 用法:push_git <token 檔> <使用者> <git 子指令...>
push_git() {
  local tf=$1 user=$2 bad rc sd; shift 2
  # 全域設定不讀,但保留使用者在全域信任的 safe.directory(外接磁碟、他人擁有的目錄)
  local -a safe=()
  while IFS= read -r sd; do [[ -n $sd ]] && safe+=(-c "safe.directory=$sd"); done \
    < <({ git config --system --get-all safe.directory; git config --global --get-all safe.directory; } 2>/dev/null || true)
  # HOME 換成空目錄:git 的 libcurl 會讀 ~/.netrc,裡面若有 github.com 會用個人憑證推送
  mkdir -p "$SCRATCH/home"
  # 推送用乾淨環境:不讀全域 / 系統設定,移除會注入設定、改 TLS / proxy / 除錯輸出的環境變數
  local -a clean=(env -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_CONFIG_COUNT
    -u GIT_SSL_NO_VERIFY -u GIT_SSL_CAINFO -u GIT_SSL_CAPATH -u GIT_SSL_CERT -u GIT_SSL_KEY
    -u GIT_HTTP_PROXY_AUTHMETHOD -u GIT_PROXY_SSL_CERT -u GIT_PROXY_SSL_KEY -u GIT_PROXY_SSL_CAINFO
    -u GIT_TRACE -u GIT_TRACE_CURL -u GIT_CURL_VERBOSE -u GIT_TRACE_PACKET -u GIT_ASKPASS -u SSH_ASKPASS
    -u http_proxy -u https_proxy -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY
    -u CURL_CA_BUNDLE -u SSL_CERT_FILE -u SSL_CERT_DIR -u GIT_SSL_CERT_PASSWORD_PROTECTED
    -u XDG_CONFIG_HOME -u NETRC
    HOME="$SCRATCH/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0)
  # repo 的任何設定檔(local、worktree、include / includeIf)都不得有 url.* / http.* / credential.*:
  # 這些能改寫推送網址、走 proxy、關 TLS 驗證、附加別的認證或 helper
  # 只有 exit 1(沒有符合)才算乾淨;其他錯誤(git 太舊、include 壞掉、dubious ownership)一律拒絕
  bad=$("${clean[@]}" git ${safe[@]+"${safe[@]}"} config --show-scope --includes --name-only \
          --get-regexp '^(url|http|credential)\..*$' 2>&1) && rc=0 || rc=$?
  [[ $rc -eq 0 || $rc -eq 1 ]] || die "無法檢查 repo 設定(git config exit $rc):$bad"
  # 無害、常見的 http 調校設定允許(不能改網址、proxy、TLS、認證)
  [[ $rc -eq 0 ]] && bad=$(grep -viE '[[:space:]]http\.(postbuffer|version|lowspeedlimit|lowspeedtime|maxrequests|minsessions)$' <<<"$bad" || true)
  [[ $rc -eq 1 || -z $bad ]] || die "repo 設定有會影響推送認證或網址的項目,請先移除:$(tr '\n' ' ' <<<"$bad")"
  "${clean[@]}" \
  git ${safe[@]+"${safe[@]}"} -c credential.helper= \
      -c "credential.https://github.com.helper=!f() { echo username=$user; printf 'password=%s\n' \"\$(cat '$tf')\"; }; f" \
      -c push.recurseSubmodules=no -c submodule.recurse=false \
      -c core.hooksPath=/dev/null \
      -c http.extraHeader= -c http.sslVerify=true -c http.proxy= -c http.cookieFile= \
      -c user.name=bot -c user.email=bot@invalid \
      "$@"
}

cmd_push() {
  local branch=${1:-}; [[ -n $branch && $# -eq 1 ]] || die "用法:bot.sh push <分支>"
  [[ $branch =~ ^[A-Za-z0-9._/-]+$ && $branch != -* && $branch != HEAD && $branch != refs/* ]] \
    && git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "分支名稱不合法:$branch"
  case $branch in main|master) die "不推 $branch;請推功能分支再開 PR" ;; esac
  # 推送時停用 hooks、換掉 HOME,git-lfs 的 pre-push 不會執行 → LFS 物件不會上傳
  if git grep -q 'filter=lfs' HEAD -- .gitattributes ':(glob)**/.gitattributes' 2>/dev/null; then
    die "這個 repo 使用 Git LFS,bot.sh push 不支援(LFS 物件不會上傳);請改用一般 git push"
  fi
  load_conf; resolve_repo
  local t user=x-access-token def
  t=$(token)
  [[ $MODE == pat ]] && { identity; user=$BOT_NAME; }
  local info; info=$(api GET "/repos/$REPO" "$t") || exit 1
  def=$(jfield .default_branch "$info")
  [[ $branch != "$def" ]] || die "不推預設分支 $def;請推功能分支再開 PR"
  token_file "$t"; unset t
  push_git "$TOKEN_TMP" "$user" push --no-recurse-submodules "https://github.com/$REPO.git" "HEAD:refs/heads/$branch"
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
  if [[ -z $base ]]; then
    local info; info=$(api GET "/repos/$REPO" "$t") || exit 1
    base=$(jfield .default_branch "$info")
  fi
  local r
  r=$(api POST "/repos/$REPO/pulls" "$t" \
    "$(jq -nc --arg h "$head" --arg b "$base" --arg t "$title" --arg d "$body" \
        '{head:$h, base:$b, title:$t, body:$d}')")
  jfield .html_url "$r"
}

# CI 檢查。剛推完時 CI 還沒登記(mergeable_state 會先顯示 clean),所以先等 CI 出現再判斷:
#   - repo 有 .github/workflows:等到至少一個 GitHub Actions workflow run
#   - 沒有 workflow:等到任何 check run 或 commit status(CircleCI 等外部 CI)
#   出現後再觀察 15 秒(3 次輪詢數量不變)才判斷,避免晚幾秒才登記的 workflow 被漏掉。
#   最多等約 2 分鐘;沒有 CI 就拒絕,確定這個 repo / commit 沒有 CI 才加 --allow-no-ci(不等待)。
# 有任何 check suite / check run / commit status 未完成或失敗一律拒絕(未完成就稍後再跑 merge)。
ci_snapshot() {   # 設定 runs st suites wruns nr ns nw
  runs=$(api GET "/repos/$REPO/commits/$sha/check-runs?filter=all&per_page=100" "$t") \
    || die "讀不到 check runs(若上面是 HTTP 403 / 404:App 要加 Checks: Read 權限)"
  suites=$(api GET "/repos/$REPO/commits/$sha/check-suites?per_page=100" "$t") \
    || die "讀不到 check suites(若上面是 HTTP 403 / 404:App 要加 Checks: Read 權限)"
  st=$(api GET "/repos/$REPO/commits/$sha/status" "$t") \
    || die "讀不到 commit status(若上面是 HTTP 403 / 404:App 要加 Commit statuses: Read 權限)"
  wruns=$(api GET "/repos/$REPO/actions/runs?head_sha=$sha&per_page=100" "$t") \
    || die "讀不到 GitHub Actions workflow runs(若上面是 HTTP 403 / 404:App 要加 Actions: Read 權限)"
  nr=$(jq -r '.total_count' <<<"$runs"); ns=$(jq -r '.total_count' <<<"$st"); nw=$(jq -r '.total_count' <<<"$wruns")
  [[ $nr -le $(jq -r '.check_runs | length' <<<"$runs") ]] || die "check runs 超過 100 個,無法全部確認,不合併"
  [[ $(jq -r '.total_count' <<<"$suites") -le $(jq -r '.check_suites | length' <<<"$suites") ]] \
    || die "check suites 超過 100 個,無法全部確認,不合併"
  [[ $nw -le $(jq -r '.workflow_runs | length' <<<"$wruns") ]] || die "workflow runs 超過 100 個,無法全部確認,不合併"
}

# CI 判斷:
#   - GitHub Actions workflow:以 workflow runs API 為準。每個 (workflow, 觸發事件) 取這個 commit 上
#     最新一次 run(重跑會更新同一個 run),必須 completed 且 success / neutral / skipped;排隊中、
#     需要核准、被取消(例如 concurrency)、失敗一律拒絕。被取消就重跑那個 workflow 再合併。
#   - check run:抓這個 commit 的全部 run(filter=all),排除「被同 workflow + 同事件的新 run 取代」的
#     舊 suite 與 --ignore-suite 指定的 suite,其餘(含 workflow 自己建立的測試報告等)都必須成功。
#   - 其他 App 的 check suite(有 run 的)、commit status:必須完成且成功。
#   - 確定永遠不會跑的項目,用 --ignore-suite <check suite id> 明確略過(錯誤訊息會列出 id);
#     有略過時 GitHub 的 mergeable_state 會是 unstable,merge 會接受(仍尊重分支規則 blocked)。
# 等待:先等 CI 登記(有 workflow 的 repo 要等到 Actions 的 workflow run;沒有就等任何 CI),
# 登記後觀察 15 秒數量不變才判斷;60 秒都沒有就拒絕,除非 --allow-no-ci。不會等 CI 跑完。
check_ci() {
  local sha=$1 t=$2 allow_no_ci=$3 ignore_suites=${4:-} runs st suites wruns nr ns nw wf rc
  local has_wf=0 ready=0 stable=0 last=-1 bad i
  wf=$(api_try GET "/repos/$REPO/contents/.github/workflows?ref=$sha" "$t") && rc=0 || rc=$?
  case $rc in
    0) [[ $(jq -r 'if type=="array" then map(select(.name | test("\\.ya?ml$"))) | length else 0 end' <<<"$wf") -gt 0 ]] && has_wf=1 ;;
    4) ;;
    *) die "查不到 repo 是否有 workflow,不合併" ;;
  esac
  for i in $(seq 24); do
    ci_snapshot
    if [[ $has_wf -eq 1 ]]; then [[ $nw -gt 0 ]] && ready=1; else [[ $((nr + ns + nw)) -gt 0 ]] && ready=1; fi
    # --allow-no-ci:沒有 workflow 時仍等 15 秒給外部 CI 登記;有 workflow 時等滿 60 秒
    [[ $ready -eq 0 && $allow_no_ci -eq 1 && $has_wf -eq 0 && $i -ge 4 ]] && break
    if [[ $ready -eq 1 ]]; then
      if [[ $((nr + ns + nw)) -eq $last ]]; then stable=$((stable + 1)); else stable=0; last=$((nr + ns + nw)); fi
      [[ $stable -ge 3 ]] && break
    fi
    [[ $ready -eq 0 && $i -ge 13 ]] && break       # 60 秒內都沒出現就放棄等待
    sleep 5
  done
  if [[ $ready -eq 0 && $allow_no_ci -ne 1 ]]; then
    if [[ $has_wf -eq 1 ]]; then
      die "repo 有 GitHub Actions workflow,但等了 60 秒這個 commit 仍沒有 GitHub Actions 的 workflow run;若 workflow 不在 PR 分支觸發,確認後加 --allow-no-ci"
    fi
    die "等了 60 秒這個 commit 沒有任何 CI 結果;確定這個 repo 沒有 CI 才加 --allow-no-ci"
  fi
  [[ $ready -eq 0 || $stable -ge 3 ]] || die "CI 數量一直在變動(還在陸續登記),稍後再合併"
  # 以下對「目前已有的」CI 一律檢查(--allow-no-ci 也一樣)
  local ok='IN("success","neutral","skipped")' skip
  # 被取代的 workflow run(同 workflow + 同事件的較舊 run)所屬 suite id,加上使用者指定略過的
  skip=" $ignore_suites $(jq -r '.workflow_runs | group_by([.workflow_id, .event])
          | map(sort_by(.created_at, (.run_attempt // 1)) | .[:-1][] | .check_suite_id) | map(tostring) | join(" ")' <<<"$wruns") "
  bad=$(jq -r --arg ign " $ignore_suites " ".workflow_runs
          | group_by([.workflow_id, .event]) | map(sort_by(.created_at, (.run_attempt // 1)) | last) | .[]
          | . as \$w | select((\$ign | contains(\" \(\$w.check_suite_id) \")) | not)
          | select(.status != \"completed\" or ((.conclusion // \"\") | $ok | not))
          | \"workflow:\(.name)(\(.event))#\(.check_suite_id)=\(.conclusion // .status)\"" <<<"$wruns")
  bad+=$'\n'$(jq -r --arg ign " $ignore_suites " ".check_suites[]
          | select(.app.slug != \"github-actions\" and (.latest_check_runs_count // 0) > 0)
          | . as \$su | select((\$ign | contains(\" \(\$su.id) \")) | not)
          | select(.status != \"completed\" or ((.conclusion // \"\") | $ok | not))
          | \"suite:\(.app.slug)#\(.id)=\(.conclusion // .status)\"" <<<"$suites")
  bad+=$'\n'$(jq -r --arg skip "$skip" ".check_runs[]
          | . as \$r | select((\$skip | contains(\" \((\$r.check_suite.id // 0)) \")) | not)
          | select(.status != \"completed\" or ((.conclusion // \"\") | $ok | not))
          | \"run:\(.name)#\(.check_suite.id // 0)=\(.conclusion // .status)\"" <<<"$runs")
  bad=$(grep -v '^[[:space:]]*$' <<<"$bad" || true)
  [[ -z $bad ]] || die "CI 未完成或失敗,不合併:$(tr '\n' ' ' <<<"$bad")(被取消就重跑;確定某項永遠不會跑才用 --ignore-suite <id> 略過)"
  [[ $ns -eq 0 || $(jq -r '.state' <<<"$st") == success ]] \
    || die "commit status 為 $(jq -r .state <<<"$st"),不合併"
}

cmd_merge() {
  local num=${1:-} sha="" method=merge allow_no_ci=0 ignore_suites=""
  [[ $num =~ ^[0-9]+$ ]] || die "用法:bot.sh merge <PR 號碼> --sha <SHA> [--method merge|squash|rebase] [--allow-no-ci] [--ignore-suite <id>]..."
  shift
  while [[ $# -gt 0 ]]; do
    case $1 in
      --sha) need_val "$1" $#; sha=$2; shift 2 ;;
      --method) need_val "$1" $#; method=$2; shift 2 ;;
      --allow-no-ci) allow_no_ci=1; shift ;;
      --ignore-suite) need_val "$1" $#; [[ $2 =~ ^[0-9]+$ ]] || die "--ignore-suite 要數字 id"; ignore_suites+=" $2"; shift 2 ;;
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
  [[ $(jq -r '.mergeable_state // ""' <<<"$pr") != dirty ]] || die "PR #$num 有衝突,無法合併"
  # 先看 CI:CI 進行中時 mergeable_state 會是 unstable / blocked,由 check_ci 給出準確的原因
  check_ci "$sha" "$t" "$allow_no_ci" "$ignore_suites"
  for i in 1 2 3 4 5 6 7 8 9 10; do        # GitHub 還在算時 mergeable_state 為 unknown
    pr=$(api GET "/repos/$REPO/pulls/$num" "$t")
    [[ $(jq -r .head.sha <<<"$pr") == "$sha" ]] || die "PR #$num head 已不是 $sha(review 後有新 commit,請重新 review)"
    st=$(jq -r '.mergeable_state // "unknown"' <<<"$pr")
    [[ $st != unknown || $i -eq 10 ]] && break
    sleep 2
  done
  case $st in
    clean|has_hooks) ;;
    dirty)    die "PR #$num 有衝突,無法合併" ;;
    unstable) [[ -n $ignore_suites ]] \
                || die "PR #$num 有失敗或未完成的檢查,不合併" ;;   # --ignore-suite 略過的項目會讓 GitHub 顯示 unstable;CI 已由 check_ci 判斷
    blocked)  die "PR #$num 被分支規則擋住(需要 approval 或必要檢查),不合併" ;;
    behind)   die "PR #$num 落後 base,分支規則要求先更新" ;;
    *)        die "PR #$num 狀態不允許合併(mergeable_state=$st)" ;;
  esac
  local r
  r=$(api PUT "/repos/$REPO/pulls/$num/merge" "$t" \
    "$(jq -nc --arg s "$sha" --arg m "$method" '{sha:$s, merge_method:$m}')")
  jfield .sha "$r"
}

[[ ${1:-} == --repo ]] && { need_val --repo $#; [[ -n $2 ]] || die "--repo 不能是空的"; REPO=${2%.git}; shift 2; }
[[ -z $REPO ]] || valid_repo "$REPO" || die "--repo 格式錯誤:$REPO"

if [[ ${1:-} == _* && ${GITHUB_BOT_TEST:-} != 1 ]]; then
  die "_ 開頭的指令只給測試用(需 GITHUB_BOT_TEST=1)"
fi

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
  _scratch) echo "$SCRATCH"; [[ ${2:-} == hang ]] && { /bin/sleep 30 & CHILD_PID=$!; echo "$CHILD_PID"; wait $CHILD_PID; } ;;   # 測試用:印出暫存目錄(可選擇卡住等訊號)
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
