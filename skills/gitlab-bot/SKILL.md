---
name: gitlab-bot
description: 在自建 GitLab(或 gitlab.com)上 commit、push 功能分支、開 Merge Request,自己 code review 沒問題就合併(只自動合併沒有 CI 的專案,有 CI 交給使用者)。支援多專案:主機與專案路徑從 origin 自動解析,token 從 macOS 鑰匙圈(service=gitlab-bot、account=<主機>)取,同一主機所有專案共用一筆。主 agent 要把變更推上 GitLab 並開 MR,或使用者說「推到 GitLab」「開 MR」「合併 MR」時使用。不直接推 main / master / 預設分支,不 force-push,只合併 review 過的 SHA。
---

# gitlab-bot

腳本:`scripts/bot.sh`(只需 bash、curl、jq、git、python3、macOS `security`)。

## 一次性設定(每台 GitLab 主機一次)

1. GitLab → 頭像 → Preferences → **Access Tokens**:scope **`api` + `write_repository`**(兩個都要),設到期日。
   只給 `read_api` 時 push 前的查詢都會過,但開 MR 會 `403 insufficient_scope`;缺 `write_repository` 則無法 push。
   (要機器人身分:改用 Group Access Token 或專用機器人帳號的 PAT,存法相同。)
2. 存進鑰匙圈(使用者自己在終端機輸入,不要貼進對話):
   `security add-generic-password -s gitlab-bot -a <主機,例如 gitlab.example.com> -w`
3. 驗證:在該主機任一 repo 內執行 `bash $BOT identity`、`bash $BOT project`。兩者都會印出 token 名稱、scopes、到期日;
   缺 `api` 或 `write_repository` 時印警告並以結束碼 3 結束(資訊仍會先印完)。查不到 scope(某些 token 類型不支援
   `/personal_access_tokens/self`)時只印「無法確認 scope」,不算失敗。
4. 建議專案的 `main` 設為 Protected branch(Allowed to push: No one)。

換 token:`security delete-generic-password -s gitlab-bot -a <主機>` 後重做第 2 步。

## 用法(在要操作的 repo 目錄內;origin 決定主機與專案)

```bash
BOT=~/.claude/skills/gitlab-bot/scripts/bot.sh
bash $BOT project                       # 預設分支、權限、是否有 CI、受保護分支
git switch -c <功能分支>
git add <檔案>
bash $BOT commit -m "訊息"              # 以 token 擁有者身分 commit(其他 git commit 參數照傳)
bash $BOT push <功能分支>                # 推 HEAD 到遠端同名分支
bash $BOT mr --head <功能分支> --title "標題" --body-file <內文.md>   # 印 MR 網址;--base 預設為預設分支
bash $BOT merge <MR iid> --sha <review 過的完整 SHA>
```

- push 拒絕 `main`、`master`、預設分支,不支援 force;改歷史先問使用者。
- token 不進指令列、環境變數、remote URL 或 `.git/config`:API 經 stdin 給 curl,push 時只在 0700 暫存目錄的 0600 檔給 credential helper 讀,結束即刪;helper 只綁 origin 的主機(`credential.https://<主機>.helper`),不會送給別的主機。push 不讀全域/系統 git 設定(保留 safe.directory)、HOME 換成空目錄、停用 hooks、不遞迴推 submodule(`--no-recurse-submodules`),並移除 proxy、TLS、SSH、trace 類環境變數;repo 的任何設定檔(local、worktree、include)有 `url.*`、`credential.*`、`http.*`(`postBuffer`、`version`、`lowSpeedLimit`、`lowSpeedTime`、`maxRequests`、`minSessions` 除外)、`remote.<網址>.*`(例如 pushurl)、`core.sshCommand` 就拒絕。
- 平行任務在各自 worktree 執行即可(worktree 共用 origin)。

## 自己 review 後合併

1. `bash $BOT mr ...` 開 MR,記下 `HEAD_SHA=$(git rev-parse HEAD)`。
2. 用 `code-review` skill 審這個分支相對預設分支的變更。
3. 有 `important` → 修好、commit、push、更新 HEAD_SHA,回第 2 步。只剩 `nit` / `pre_existing` / 無發現 → 可合併。測試失敗、有衝突、需要使用者決定的產品問題 → 不合併,回報。
4. `bash $BOT merge <iid> --sha $HEAD_SHA`。偵測到 CI 或無法確認就拒絕(exit 2)→ 回報使用者,讓使用者看過 CI 後自己合併:
   - head 與目標分支目前的 commit 任一有 `.gitlab-ci.yml`、pipeline、commit status,或 MR 本身有 pipeline;
   - 專案設了自訂 `ci_config_path`、開了 Auto DevOps、規定 pipeline 成功才能合併;
   - 專案回應沒有這三個欄位(Developer 權限的 token 看不到)→ 視為無法確認。要讓 bot 自己合併,token 擁有者需要 Maintainer。
   - 外部 CI 可能晚登記:等 15 秒(4 次查詢)都沒有才算沒有 CI,合併前再確認一次。任何查詢失敗都不合併(exit 1)。
5. 回報:MR 網址、review 結論、merge commit SHA。使用者沒授權自動合併時,停在第 3 步回報即可。

## 自我測試

```bash
bash skills/gitlab-bot/tests/run.sh
```

離線執行(只需 bash、python3、jq、git、curl):`tests/mock_api.py` 是只聽 127.0.0.1 的假 GitLab API,push 推到暫存的本機 bare repo。
涵蓋 identity / project 的 scope 檢查、push 拒絕規則(含 pushurl、worktree / include 設定)、helper 綁主機、不遞迴 submodule 與 token 不落地、mr 建立與沿用、merge 的各種拒絕情況(目標分支、MR pipeline、晚登記的 CI、缺欄位、查詢失敗),以及兩個真實踩過的 bug:
回應 JSON 字串含未跳脫控制字元(jq 直接解析會失敗)、`detailed_merge_status` 先 `unchecked` / `checking` 才變 `mergeable`;
並在暫存複本上拿掉對應修正做反向驗證。

測試用環境變數(正式使用不要設;只接受本機,避免 token 被送到別處,不符就在取 token 前拒絕):

- `GITLAB_BOT_TOKEN_CMD`:改用這個指令取 token(取代鑰匙圈)。
- `GITLAB_BOT_API_URL`:只接受 `http://127.0.0.1:<port>` 或 `http://localhost:<port>`,取代從 origin 推出的 `https://<主機>`(API 仍走 `/api/v4`)。
- `GITLAB_BOT_PUSH_URL`:只接受本機絕對路徑或 `file:///...`,push 改推到這裡。
