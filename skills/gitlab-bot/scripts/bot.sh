#!/usr/bin/env bash
# GitLab(自建或 gitlab.com)機器人:token 從 macOS 鑰匙圈取,commit、push 功能分支、開 MR、review 後合併。
#   bot.sh identity                         印出 token 擁有者與 commit 用的 name / email
#   bot.sh project                          印出專案資訊(id、預設分支、權限、是否有 CI)
#   bot.sh commit <git commit 參數...>      以 token 擁有者身分 git commit
#   bot.sh push <分支>                      把 HEAD 推到遠端 <分支>(拒絕預設分支、main、master,不 force)
#   bot.sh mr --head <分支> [--base <分支>] --title <標題> [--body-file <檔>]
#                                           開 MR,印出網址;該分支已有 open MR 就印既有網址
#   bot.sh merge <MR iid> --sha <review 過的 head SHA> [--wait-ci <分鐘>]
#                                           沒有 CI:確認 15 秒內沒有晚登記的 CI 才合併。
#                                           有 CI:這個 head 的 pipeline / commit status 全部通過才合併;
#                                           還在跑時等到 --wait-ci 分鐘(預設 0 = 不等)。
#                                           結束碼:2 = CI 失敗 / 無法判定、4 = CI 還在跑(等不到)
#   bot.sh jobs <pipeline id>               列出 pipeline 的 job(id、stage、名稱、狀態)
#   bot.sh log <job id> [行數]              印 job log 的最後幾行(預設 200,最多 5000)
#   bot.sh retry <pipeline id>              重跑 pipeline 裡失敗 / 取消的 job
#   bot.sh tag <vX.Y.Z> --sha <完整 SHA> [-m <訊息>]
#                                           在預設分支上的 commit 建立 annotated tag(GitLab API,不 push);
#                                           tag 已存在、SHA 不在預設分支上就拒絕,不覆寫、不刪除
#   bot.sh fetch [分支…]                    從 origin 抓分支到 refs/remotes/origin/<分支>(預設:預設分支;唯讀,token 處理同 push)
#   bot.sh rebase <MR iid>                  請 GitLab 把 MR 的來源分支 rebase 到目標分支（同網頁上的 Rebase 按鈕；
#                                           本機不 force-push），等到完成後印出新的 head SHA（要重新 review / 等 CI）
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
elif [[ $ORIGIN =~ ^ssh://git@([A-Za-z0-9.-]+)(:[0-9]+)?/(.+)$ ]]; then
  HOST=${BASH_REMATCH[1]}; PORT=""; PPATH=${BASH_REMATCH[3]}
elif [[ $ORIGIN =~ ^git@([A-Za-z0-9.-]+):(.+)$ ]]; then   # scp 格式沒有埠號,冒號後面就是路徑(群組可以是數字)
  HOST=${BASH_REMATCH[1]}; PORT=""; PPATH=${BASH_REMATCH[2]}
else
  die "看不懂 origin 網址:$(sed -E 's#//[^/@]*@#//***@#' <<<"$ORIGIN")"
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
  : >"$out"   # 空回應時 curl 不會截斷,先清空,避免讀到上一個呼叫的內容
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
  [[ -n $EMAIL ]] || EMAIL="$(jq -r '"\(.id)-\(.username)"' <<<"$u")@users.noreply.$HOST"   # GitLab 私人信箱格式 <id>-<username>
  USERNAME=$(jq -r .username <<<"$u")
}

project_json() { api GET "/projects/$PID_ENC"; }

# api_text:回應是純文字(job log),不做 JSON 解析;非 2xx 回 1
api_text() {
  local path=$1 out=$SCRATCH/resp code
  : >"$out"
  code=$(printf 'PRIVATE-TOKEN: %s\n' "$TOKEN" | curl -q -sS -o "$out" -w '%{http_code}' -H @- "$API$path") || die "連不到 $API"
  [[ $code == 2* ]] || { echo "bot.sh: GitLab API GET $path → HTTP $code" >&2; return 1; }
  cat "$out"
}

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

# 推送用的乾淨 git:不讀全域/系統設定、HOME 為空目錄、停用 hooks、不遞迴推 submodule;
# token 只在 0600 暫存檔給 credential helper,helper 只綁 origin 的主機($BASE),送不到別的主機
# clean_git <git 參數…>:在隔離環境(同 push 的檢查與 token 處理)對 origin 執行網路操作(push / fetch)
clean_git() {
  local bad rc sd
  # 全域設定不讀,但保留使用者在全域信任的 safe.directory(外接磁碟、他人擁有的目錄);
  # 逐筆用 git 的 --type=path 把 ~/ 展開成絕對路徑(之後 HOME 會換成空目錄);展不開的(例如不存在的 ~user)
  # 跳過並警告(原值傳給 git 會讓 git 直接 fatal),不影響其他項目;空值 = 清除前面的項目(跟 git 一樣)
  local -a safe=()
  while IFS= read -r -d '' sd; do
    if [[ -z $sd ]]; then safe=(); continue; fi
    # 每筆都交給 git 展開(~/、~user、%(prefix)/、:(optional));:(optional) 指向不存在的路徑時 git 回 1 且無輸出 → 靜默略過
    local raw=$sd
    sd=$(cd / && env -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -c "botsafe.dir=$raw" config --type=path botsafe.dir 2>/dev/null) || {
      [[ $raw == ':(optional)'* ]] || echo "警告:safe.directory「${raw}」展不開,略過" >&2; continue; }
    safe+=(-c "safe.directory=$sd")
  done < <({ env -u GIT_CONFIG git config --system --includes --null --get-all safe.directory; env -u GIT_CONFIG git config --global --includes --null --get-all safe.directory; } 2>/dev/null || true)
  mkdir -p "$SCRATCH/home"
  local -a clean=(env -u GIT_CONFIG -u GIT_CONFIG_COUNT -u GIT_CONFIG_PARAMETERS -u GIT_ASKPASS -u SSH_ASKPASS
    -u GIT_SSL_NO_VERIFY -u GIT_SSL_CAINFO -u GIT_SSL_CAPATH -u GIT_SSL_CERT -u GIT_SSL_KEY -u GIT_SSL_CERT_PASSWORD_PROTECTED
    -u GIT_HTTP_PROXY_AUTHMETHOD -u GIT_PROXY_SSL_CERT -u GIT_PROXY_SSL_KEY -u GIT_PROXY_SSL_CAINFO
    -u SSL_CERT_FILE -u SSL_CERT_DIR -u CURL_CA_BUNDLE -u GIT_EXEC_PATH -u NO_PROXY -u no_proxy
    -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u all_proxy
    -u GIT_TRACE -u GIT_TRACE_CURL -u GIT_TRACE_PACKET -u GIT_TRACE_SETUP -u GIT_TRACE_REDACT -u GIT_CURL_VERBOSE
    -u GIT_TRACE_PERFORMANCE -u GIT_TRACE_PACK_ACCESS -u GIT_TRACE_SHALLOW -u GIT_TRACE_REFS -u GIT_SSL_VERSION -u GIT_SSL_CIPHER_LIST
    -u GIT_TRACE2 -u GIT_TRACE2_EVENT -u GIT_TRACE2_PERF -u GIT_TRACE2_CONFIG_PARAMS -u GIT_TRACE2_ENV_VARS -u SSLKEYLOGFILE
    -u XDG_CONFIG_HOME -u NETRC -u GIT_SSH -u GIT_SSH_COMMAND
    HOME="$SCRATCH/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0)
  # repo 的任何設定檔(local、worktree、include / includeIf)都不得有能改寫網址 / 認證 / TLS / proxy 的項目:
  # url.*、http.*(少數無害調校除外)、credential.*、remote.<網址>.*(推到網址時 git 會套用,例如 pushurl)、core.sshCommand。
  # 只有 exit 1(沒有符合)才算乾淨;其他錯誤(include 壞掉)一律拒絕。
  # dubious ownership 時 git config 會略過 local 設定並回 1,所以先確認 repo 讀得到
  "${clean[@]}" git ${safe[@]+"${safe[@]}"} rev-parse --git-dir >/dev/null 2>&1 \
    || die "這個 repo 不受信任或讀不到(dubious ownership?),請在全域設定 safe.directory 後再推"
  bad=$("${clean[@]}" git ${safe[@]+"${safe[@]}"} config --show-scope --includes --name-only \
          --get-regexp '^((url|http|credential)\..*|remote\.[a-z+]+://.*|remote\./.*|core\.sshcommand)$' 2>"$SCRATCH/cfgerr") && rc=0 || rc=$?
  [[ $rc -eq 0 || $rc -eq 1 ]] || die "無法檢查 repo 設定(git config exit $rc):$(head -c 500 "$SCRATCH/cfgerr")"
  [[ $rc -eq 0 ]] && bad=$(grep -viE '[[:space:]]http\.(postbuffer|version|lowspeedlimit|lowspeedtime|maxrequests|minsessions)$' <<<"$bad" || true)
  [[ $rc -eq 1 || -z $bad ]] || die "repo 設定含會影響推送的項目,拒絕推送:
$bad"
  (umask 077; printf '%s' "$TOKEN" > "$SCRATCH/t")
  local helper="!f(){ test \"\$1\" = get && printf 'username=oauth2\\npassword=%s\\n' \"\$(cat $SCRATCH/t)\"; }; f"
  "${clean[@]}" \
    git ${safe[@]+"${safe[@]}"} -c credential.helper= -c "credential.$BASE.helper=$helper" -c credential.useHttpPath=false \
      -c push.recurseSubmodules=no -c submodule.recurse=false -c core.hooksPath=/dev/null \
      -c http.extraHeader= -c http.sslVerify=true -c http.proxy= -c http.cookieFile= \
      -c fetch.recurseSubmodules=false "$@"
  rm -f "$SCRATCH/t"
}

clean_push() {
  local branch=$1
  clean_git push --no-recurse-submodules "$PUSH_URL" "HEAD:refs/heads/$branch"
  # 只有推到 origin 時才更新本機的 origin 追蹤分支(GITLAB_BOT_PUSH_URL 指到別處時不更新)
  [[ -n ${GITLAB_BOT_PUSH_URL:-} ]] || git update-ref "refs/remotes/origin/$branch" HEAD 2>/dev/null || true
}

# ci_signals <head SHA> <目標分支>:把 CI 跡象(或無法確認沒有 CI 的原因)放進 CI_FOUND;查詢失敗 exit 1。
# 有任何一條就表示「預期有 CI」,要走 ci_gate(pipeline 通過才合併),不能當成沒有 CI。
# 不在子 shell 呼叫,die 才會結束整個腳本。
nonneg() { [[ ${1-} =~ ^[0-9]+$ ]] || die "$2 查詢回應不是預期的 JSON,不合併"; }
ci_signals() {
  local sha=$1 tgt=$2 found=() pj cip k v r tsha n c tq
  pj=$(project_json) || die "查不到專案設定,不合併"
  jq -e 'type=="object"' >/dev/null 2>&1 <<<"$pj" || die "專案設定的回應不是預期的 JSON,不合併"
  # Developer 權限的 token 看不到這些欄位;缺欄位 = 無法確認,不能當成沒有 CI
  for k in ci_config_path auto_devops_enabled only_allow_merge_if_pipeline_succeeds; do
    jq -e --arg k "$k" 'has($k)' >/dev/null <<<"$pj" || found+=("專案回應沒有 $k 欄位(token 權限可能不足,需要 Maintainer),無法確認沒有 CI")
  done
  # 專案設了自訂 CI 設定路徑(ci_config_path,含遠端設定)→ 視為有 CI;pipeline 可能還沒建立,不能靠 pipelines 查詢
  cip=$(jq -r '.ci_config_path // empty' <<<"$pj")
  [[ -z $cip || $cip == .gitlab-ci.yml ]] || found+=("專案設定自訂 CI 設定路徑:$cip")
  # Auto DevOps / 規定 pipeline 成功才能合併:沒有 CI 檔也會跑 CI(pipeline 可能還沒建立)
  for k in "auto_devops_enabled:專案開啟 Auto DevOps" "only_allow_merge_if_pipeline_succeeds:專案規定 pipeline 成功才能合併"; do
    v=$(jq -r --arg k "${k%%:*}" '.[$k] | if . == null then "false" else tostring end' <<<"$pj")
    case $v in false) ;; true) found+=("${k#*:}") ;; *) found+=("${k%%:*} 的值不是 true / false($v),無法確認") ;; esac
  done
  # 目標分支目前的 commit:目標分支上才有的 CI(外部 CI、只在目標分支跑的 pipeline)合併後就會觸發
  tq=$(jq -rn --arg b "$tgt" '$b|@uri')
  r=$(api GET "/projects/$PID_ENC/repository/branches/$tq") || die "查不到目標分支 $tgt,不合併"
  tsha=$(jq -r '.commit.id // empty' <<<"$r"); [[ $tsha =~ ^[0-9a-f]{40}$ ]] || die "目標分支 $tgt 的回應不是預期的 JSON,不合併"
  for c in "$sha:head" "$tsha:$tgt"; do
    case $(ci_file_at "${c%%:*}") in
      no) ;;
      yes) found+=("${c#*:} 有 .gitlab-ci.yml") ;;
      *) die "無法確認 ${c#*:} 有沒有 .gitlab-ci.yml,不合併" ;;
    esac
    r=$(api GET "/projects/$PID_ENC/pipelines?sha=${c%%:*}") || die "查不到 ${c#*:} 的 pipeline,不合併"
    n=$(jq -r 'if type=="array" then length else "x" end' <<<"$r"); nonneg "$n" pipeline
    [[ $n == 0 ]] || found+=("${c#*:} 有 $n 個 pipeline")
    r=$(api GET "/projects/$PID_ENC/repository/commits/${c%%:*}/statuses") || die "查不到 ${c#*:} 的 commit status,不合併"
    n=$(jq -r 'if type=="array" then length else "x" end' <<<"$r"); nonneg "$n" "commit status"
    [[ $n == 0 ]] || found+=("${c#*:} 有 $n 個 commit status")
  done
  # MR pipeline(detached / merged results)不一定掛在 head SHA 上
  r=$(api GET "/projects/$PID_ENC/merge_requests/$iid/pipelines") || die "查不到 MR 的 pipeline,不合併"
  n=$(jq -r 'if type=="array" then length else "x" end' <<<"$r"); nonneg "$n" "MR pipeline"
  [[ $n == 0 ]] || found+=("MR 有 $n 個 pipeline")
  CI_FOUND=(); [[ ${#found[@]} -eq 0 ]] || CI_FOUND=("${found[@]}")
}

# ci_class:stdin 是 [{status, allow_failure?}],印 ok / wait / bad(全部 ok 才是 ok;有 bad 就是 bad)
ci_class() {
  jq -r 'def one: if .status == "success" then "ok"
                  elif .status == "skipped" and .kind == "status" then "ok"
                  elif (.allow_failure == true) and .kind == "status" and (.status|IN("failed","canceled","manual")) then "ok"
                  elif .status|IN("created","waiting_for_resource","preparing","pending","running","scheduled") then "wait"
                  else "bad" end;
         if type != "array" then "bad"
         else (map(one)) as $c | if ($c|index("bad")) then "bad" elif ($c|index("wait")) then "wait" else "ok" end end'
}

# ci_gate <head SHA>:預期有 CI 時,這個 head 的 CI 是否全部通過。$m 是最新的 MR JSON。
# 設 CI_STATE = ok / wait / bad,CI_WHY = 原因。查詢失敗 die。
ci_gate() {
  local sha=$1 hp r c
  CI_STATE=ok CI_WHY=()
  bump() { case $1 in bad) CI_STATE=bad ;; wait) [[ $CI_STATE == bad ]] || CI_STATE=wait ;; esac; [[ $1 == ok ]] || CI_WHY+=("$2"); }
  # MR 的 head pipeline:要是這個 head 的(branch pipeline 的 sha,或 MR 的 merge ref 上的 merged results / train)
  hp=$(jq -c '.head_pipeline // null' <<<"$m")
  if [[ $hp == null ]]; then
    bump wait "MR 還沒有 head pipeline"
  elif ! jq -e --arg s "$sha" --arg i "$iid" '.sha == $s or ((.ref // "") | test("^refs/merge-requests/" + $i + "/(merge|train|head)$"))' >/dev/null <<<"$hp"; then
    bump wait "MR 的 head pipeline 還不是 $sha 的"
  else
    c=$(jq -c '[{status, kind: "pipeline"}]' <<<"$hp" | ci_class); bump "$c" "MR head pipeline #$(jq -r .id <<<"$hp") 狀態 $(jq -r .status <<<"$hp")"
  fi
  # MR 最新的 pipeline(可能比 head_pipeline 新)
  r=$(api GET "/projects/$PID_ENC/merge_requests/$iid/pipelines") || die "查不到 MR 的 pipeline,不合併"
  r=$(jq -c 'if type=="array" then (sort_by(.id) | last | if . == null then [] else [{status, kind: "pipeline", id}] end) else "x" end' <<<"$r")
  [[ $r != '"x"' ]] || die "MR pipeline 的回應不是預期的 JSON,不合併"
  c=$(ci_class <<<"$r"); bump "$c" "MR 最新的 pipeline 狀態 $(jq -r '.[0] | "#\(.id) \(.status)"' <<<"$r")"
  # 這個 head 上每個 ref 最新的 pipeline(重跑成功的舊失敗不算)
  r=$(api GET "/projects/$PID_ENC/pipelines?sha=$sha&per_page=100") || die "查不到 head 的 pipeline,不合併"
  r=$(jq -c 'if type=="array" then (group_by(.ref) | map(max_by(.id) | {status, kind: "pipeline", ref, id})) else "x" end' <<<"$r")
  [[ $r != '"x"' ]] || die "head pipeline 的回應不是預期的 JSON,不合併"
  c=$(ci_class <<<"$r"); bump "$c" "head 的 pipeline:$(jq -r 'map("#\(.id)(\(.ref)) \(.status)") | join("、")' <<<"$r")"
  # commit status(含外部 CI;預設只回每個名稱最新的一筆):allow_failure 的失敗、skipped 不擋
  r=$(api GET "/projects/$PID_ENC/repository/commits/$sha/statuses?per_page=100") || die "查不到 head 的 commit status,不合併"
  r=$(jq -c 'if type=="array" then map({status, allow_failure, name, kind: "status"}) else "x" end' <<<"$r")
  [[ $r != '"x"' ]] || die "commit status 的回應不是預期的 JSON,不合併"
  c=$(ci_class <<<"$r"); bump "$c" "head 的 commit status:$(jq -r 'map(select(.status != "success")) | map("\(.name) \(.status)") | join("、")' <<<"$r")"
}

# wait_ci <head SHA>:預期有 CI 時,等到全部通過(最多 WAIT_CI 分鐘,每 30 秒查一次);失敗 exit 2,等不到 exit 4。
wait_ci() {
  local sha=$1 deadline=$(( $(date +%s) + WAIT_CI * 60 ))
  while :; do
    m=$(api GET "/projects/$PID_ENC/merge_requests/$iid?with_merge_status_recheck=true") || die "查不到 MR !$iid"
    check_mr
    ci_gate "$sha"
    case $CI_STATE in
      ok) return 0 ;;
      bad) printf 'bot.sh: CI 沒有通過,不合併:\n' >&2; printf '  - %s\n' "${CI_WHY[@]}" >&2; exit 2 ;;
    esac
    if (( $(date +%s) >= deadline )); then
      printf 'bot.sh: CI 還在跑,不合併(可加 --wait-ci <分鐘> 等它跑完):\n' >&2; printf '  - %s\n' "${CI_WHY[@]}" >&2; exit 4
    fi
    sleep 30
  done
}

# check_mr:$m 是 open、head 等於 review 過的 $sha、沒有衝突
check_mr() {
  [[ $(jq -r .state <<<"$m") == opened ]] || die "MR !$iid 不是 open"
  [[ $(jq -r .sha <<<"$m") == "$sha" ]] || die "MR head 是 $(jq -r .sha <<<"$m"),不是 review 過的 $sha"
  [[ $(jq -r .has_conflicts <<<"$m") == false ]] || die "MR 有衝突"
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
    # Developer 權限可能查不到 protected_branches(403):不中斷,照樣印出 token scope
    prot=$(api GET "/projects/$PID_ENC/protected_branches" 2>/dev/null | jq -r '[.[].name]|join(", ")') || prot="(無法查詢,可能權限不足)"
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
    hq=$(jq -rn --arg h "$head" '$h|@uri'); bq=$(jq -rn --arg b "$base" '$b|@uri')
    existing=$(api GET "/projects/$PID_ENC/merge_requests?state=opened&source_branch=$hq&target_branch=$bq" | jq -r '.[0].web_url // empty')
    if [[ -n $existing ]]; then echo "$existing"; exit 0; fi
    body=""; [[ -z $bodyf ]] || body=$(cat "$bodyf")
    payload=$(jq -n --arg s "$head" --arg t "$base" --arg ti "$title" --arg d "$body" \
      '{source_branch:$s, target_branch:$t, title:$ti, description:$d, remove_source_branch:false}')
    api POST "/projects/$PID_ENC/merge_requests" "$payload" | jq -r .web_url ;;
  merge)
    iid=${1-}; shift || true
    [[ $iid =~ ^[0-9]+$ ]] || die "用法:bot.sh merge <MR iid> --sha <SHA>"
    sha="" WAIT_CI=0
    while [[ $# -gt 0 ]]; do
      case $1 in
        --sha) need "$@"; sha=$2; shift 2 ;;
        --wait-ci) need "$@"; WAIT_CI=$2; shift 2 ;;
        *) die "不認得的參數:$1" ;;
      esac
    done
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "--sha 要完整 40 碼 SHA"
    [[ $WAIT_CI =~ ^[0-9]{1,4}$ ]] || die "--wait-ci 要 0 ~ 9999 的整數(分鐘)"
    # GitLab 延遲計算可合併狀態(剛 push 完 sha / has_conflicts 也可能還是舊的):
    # 觸發重新檢查,unchecked / checking 時最多等 60 秒,之後才檢查 sha 與衝突
    wait_mergeable() {
      for _ in $(seq 1 20); do
        m=$(api GET "/projects/$PID_ENC/merge_requests/$iid?with_merge_status_recheck=true")
        case $(jq -r '.detailed_merge_status // .merge_status' <<<"$m") in
          unchecked|checking|preparing|approvals_syncing) sleep 3 ;;
          *) break ;;
        esac
      done
      check_mr
      [[ ${1-} == strict ]] || return 0   # 第一次只確認 sha / 衝突;狀態留到 CI 檢查之後(CI 造成的不可合併要 exit 2)
      st=$(jq -r '.detailed_merge_status // .merge_status' <<<"$m")
      case $st in
        mergeable|can_be_merged) ;;
        ci_must_pass|ci_still_running) echo "bot.sh: GitLab 狀態 $st(CI 還沒通過),不合併" >&2; exit 4 ;;
        *) die "GitLab 回報無法合併:$st" ;;
      esac
    }
    wait_mergeable
    tgt=$(jq -r .target_branch <<<"$m")
    # 外部 CI 可能晚幾秒才登記:等 15 秒(4 次查詢,間隔 5 秒)都沒有才算沒有 CI;一有跡象就改走「pipeline 通過才合併」
    for i in 1 2 3 4; do
      ci_signals "$sha" "$tgt"
      [[ ${#CI_FOUND[@]} -eq 0 && $i -lt 4 ]] || break
      sleep 5
    done
    if [[ ${#CI_FOUND[@]} -gt 0 ]]; then
      printf 'bot.sh: 有 CI,等這個 head 的 CI 全部通過才合併:\n' >&2; printf '  - %s\n' "${CI_FOUND[@]}" >&2
      wait_ci "$sha"
      wait_mergeable strict
      [[ $(jq -r .target_branch <<<"$m") == "$tgt" ]] || die "MR !$iid 的目標分支改了,請重新 review"
      ci_gate "$sha"   # 合併前再確認一次(等待期間被重跑 / 新登記的也要擋)
      [[ $CI_STATE == ok ]] || { printf 'bot.sh: 合併前 CI 狀態變了(%s),不合併:\n' "$CI_STATE" >&2; printf '  - %s\n' "${CI_WHY[@]}" >&2; exit 2; }
    else
      wait_mergeable strict   # 等待期間 MR 可能被更新
      [[ $(jq -r .target_branch <<<"$m") == "$tgt" ]] || die "MR !$iid 的目標分支改了,請重新 review"
      ci_signals "$sha" "$tgt"   # 合併前再確認一次(等待期間才登記的 CI:不合併,下次執行會走 pipeline 檢查)
      [[ ${#CI_FOUND[@]} -eq 0 ]] || { printf 'bot.sh: 合併前才出現 CI,不合併(重新執行會等 CI):\n' >&2; printf '  - %s\n' "${CI_FOUND[@]}" >&2; exit 4; }
    fi
    r=$(api PUT "/projects/$PID_ENC/merge_requests/$iid/merge" "$(jq -n --arg s "$sha" '{sha:$s, should_remove_source_branch:false}')")
    jq -r '"merged: \(.web_url)\nmerge_commit_sha: \(.merge_commit_sha // .squash_commit_sha // "(fast-forward)")"' <<<"$r" ;;
  jobs)
    [[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || die "用法:bot.sh jobs <pipeline id>"
    api GET "/projects/$PID_ENC/pipelines/$1/jobs?per_page=100&include_retried=false" \
      | jq -r '.[] | "\(.id)\t\(.stage)\t\(.name)\t\(.status)\(if .allow_failure then " (allow_failure)" else "" end)"' ;;
  log)
    [[ $# -ge 1 && $# -le 2 && $1 =~ ^[0-9]+$ ]] || die "用法:bot.sh log <job id> [行數]"
    n=${2-200}; [[ $n =~ ^[0-9]{1,4}$ && $n -ge 1 && $n -le 5000 ]] || die "行數要 1 ~ 5000"
    # 去掉 ANSI 控制碼與 GitLab 的 section 標記
    api_text "/projects/$PID_ENC/jobs/$1/trace" | tail -n "$n" | sed -E $'s/\x1b\\[[0-9;]*[A-Za-z]//g; s/section_(start|end):[0-9]+:[A-Za-z0-9_-]+\r?//g; s/\r$//' ;;
  tag)
    name="" sha="" msg=""
    [[ $# -ge 1 && ${1-} != --* && ${1-} != -m ]] && { name=$1; shift; }
    while [[ $# -gt 0 ]]; do
      case $1 in
        --sha) need "$@"; sha=$2; shift 2 ;;
        -m) need "$@"; msg=$2; shift 2 ;;
        *) die "不認得的參數:$1" ;;
      esac
    done
    [[ $name =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "用法:bot.sh tag <vX.Y.Z> --sha <完整 SHA> [-m <訊息>](只接受 vX.Y.Z)"
    [[ $sha =~ ^[0-9a-f]{40}$ ]] || die "--sha 要 40 碼完整 SHA"
    [[ -n $msg ]] || msg=$name
    # 只有 404 才算不存在;其他狀態(401、403、5xx、連不上)直接停,不帶著未知狀態往下做
    code=$(printf 'PRIVATE-TOKEN: %s\n' "$TOKEN" | curl -q -sS -o /dev/null -w '%{http_code}' -H @- \
      "$API/projects/$PID_ENC/repository/tags/$name" 2>/dev/null) || code=000
    case $code in 2*) die "tag $name 已存在(不覆寫)" ;; 404) ;; *) die "查詢 tag $name → HTTP $code,停止" ;; esac
    def=$(project_json | jq -r .default_branch)
    # SHA 在預設分支上 ⇔ 它是預設分支 head 的祖先 ⇔ merge_base(SHA, 預設分支) == SHA(不受分支數量 / 分頁影響)
    base=$(api GET "/projects/$PID_ENC/repository/merge_base?refs%5B%5D=$sha&refs%5B%5D=$(jq -rn --arg d "$def" '$d|@uri')" | jq -r '.id // empty')
    [[ $base == "$sha" ]] || die "$sha 不在預設分支 $def 上,拒絕打 tag"
    body=$(jq -nc --arg t "$name" --arg r "$sha" --arg m "$msg" '{tag_name:$t, ref:$r, message:$m}')
    api POST "/projects/$PID_ENC/repository/tags" "$body" | jq -r '"tag \(.name) → \(.target // .commit.id)  commit \(.commit.id)"' ;;
  retry)
    [[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || die "用法:bot.sh retry <pipeline id>"
    api POST "/projects/$PID_ENC/pipelines/$1/retry" | jq -r '"pipeline #\(.id) \(.status)"' ;;
  fetch)
    [[ $# -gt 0 ]] || set -- "$(project_json | jq -r .default_branch)"
    specs=()
    for br in "$@"; do
      git check-ref-format --branch "$br" >/dev/null || die "分支名稱不合法:$br"
      specs+=("+refs/heads/$br:refs/remotes/origin/$br")
    done
    clean_git fetch --no-tags --no-recurse-submodules "$PUSH_URL" "${specs[@]}"
    for br in "$@"; do echo "origin/$br $(git rev-parse "refs/remotes/origin/$br")"; done ;;
  rebase)
    [[ $# -eq 1 && $1 =~ ^[0-9]+$ ]] || die "用法:bot.sh rebase <MR iid>"
    iid=$1
    m=$(api GET "/projects/$PID_ENC/merge_requests/$iid") || die "查不到 MR !$iid"
    [[ $(jq -r .state <<<"$m") == opened ]] || die "MR !$iid 不是 open"
    before=$(jq -r .sha <<<"$m")
    api PUT "/projects/$PID_ENC/merge_requests/$iid/rebase" '{}' >/dev/null || die "GitLab 拒絕 rebase"
    # rebase_in_progress 變回 false 之後，MR 的 sha 還可能是舊的一陣子（實測 2026-11-25）：等到 sha 變了才算完成；
    # 一直沒變（本來就在目標分支最新的 commit 上）最多再等 30 秒，印出「unchanged」
    done_at=0
    for i in $(seq 1 60); do
      m=$(api GET "/projects/$PID_ENC/merge_requests/$iid?include_rebase_in_progress=true")
      if [[ $(jq -r '.rebase_in_progress // false' <<<"$m") == false ]]; then
        err=$(jq -r '.merge_error // empty' <<<"$m")
        [[ -z $err ]] || die "rebase 失敗:$err"
        after=$(jq -r .sha <<<"$m")
        if [[ $after != "$before" ]]; then echo "rebased: $before -> $after"; exit 0; fi
        (( done_at > 0 )) || done_at=$i
        if (( i - done_at >= 10 )); then echo "unchanged: $before"; exit 0; fi
      fi
      sleep 3
    done
    die "rebase 3 分鐘內沒有完成" ;;
  *)
    sed -n '2,/^set -euo pipefail$/p' "$0" | sed '$d; s/^# \{0,1\}//'; [[ -z $cmd ]] || exit 1 ;;
esac
