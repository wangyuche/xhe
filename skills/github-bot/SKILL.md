---
name: github-bot
description: 用 GitHub App 機器人(例如 xhe-bot[bot])身分 commit、push 功能分支、開 PR,自己 code review 沒問題就合併回主線(只自動合併沒有 CI 的 repo,有 CI 交給使用者)。預設用 App 私鑰簽 JWT 換短效 installation token(1 小時、只限該 repo);也支援另開機器人帳號用 classic PAT。主 agent 要把變更推上 GitHub 並開 PR,或使用者說「用 bot commit / push」「bot 開 PR」「bot 合併」時使用。不直接推 main / master / 預設分支(一律走 PR),不 force-push,只合併 review 過的 SHA。
---

# github-bot

腳本:`scripts/bot.sh`(只需 bash、openssl、curl、jq、git)。

## 一次性設定(使用者在瀏覽器做)

1. 建立 App:<https://github.com/settings/apps/new>
   - GitHub App name:例如 `xhe-bot`(commit 作者會顯示 `xhe-bot[bot]`)
   - Homepage URL:repo 網址即可
   - Webhook:取消勾選 **Active**
   - Repository permissions:**Contents: Read and write**、**Pull requests: Read and write**、**Checks: Read**、**Commit statuses: Read**、**Actions: Read**(merge 前要確認 repo 沒有 CI)(Metadata: Read 會自動帶入),其餘不要(要讓 bot 改 `.github/workflows/` 才另加 **Workflows: Read and write**,否則推送或合併含 workflow 檔的變更會被 GitHub 拒絕)
   - Where can this GitHub App be installed:**Only on this account**
2. 建好後記下頁面上的 **App ID**,往下按 **Generate a private key**,下載 `.pem`。
3. 左側 **Install App** → 選帳號 → **Only select repositories** → 勾要讓 bot 操作的 repo。
4. 放私鑰與設定(放在倉庫外,不要 commit):

   ```bash
   mkdir -p ~/.config/github-bot && chmod 700 ~/.config/github-bot
   mv ~/Downloads/xhe-bot.*.private-key.pem ~/.config/github-bot/key.pem
   chmod 600 ~/.config/github-bot/key.pem
   printf 'APP_ID=<App ID>\nKEY_FILE=~/.config/github-bot/key.pem\n' > ~/.config/github-bot/config
   ```

5. 驗證:`bash ~/.claude/skills/github-bot/scripts/bot.sh identity` 印出 name / email 即成功。

### 替代方案:機器人帳號 + PAT(machine user)

不建 App,改用另一個 GitHub 帳號當機器人(commit 作者顯示該帳號名稱,沒有 `[bot]`):

1. 用主帳號到 repo → Settings → Collaborators → 邀請機器人帳號(Write 權限),再登入機器人帳號接受邀請。
2. 機器人帳號產生 **classic** PAT(Settings → Developer settings → Tokens (classic)),設到期日。scope:放進 gh(下面第 3 步建議做法)勾 `repo` + `read:org` + `gist` + `workflow`(`gh auth login --help` 列 `repo`、`read:org`、`gist`,互動式貼 token 時則要求 `repo`、`read:org`、`workflow`);用 token 檔則 `public_repo` 即可(private repo 要 `repo`,改 workflow 檔再加 `workflow`)。fine-grained PAT 無法存取「別人個人帳號底下」的 repo,所以要用 classic。
3. **建議:token 放 gh(macOS 鑰匙圈,平常磁碟上沒有明文;只有 push 期間短暫寫進 0700 暫存目錄,結束或被中斷即刪除)**。gh 可同時登入多個帳號,不必切換,bot 用 `gh auth token --user` 取機器人的 token,gh 平常仍停在主帳號:

   ```bash
   gh auth login                     # 主帳號(已登入可略過)
   gh auth login                     # 再登入機器人帳號,選 Paste an authentication token
   gh auth switch --user <主帳號>     # 讓主帳號保持為 active
   mkdir -p ~/.config/github-bot && chmod 700 ~/.config/github-bot
   printf 'GH_USER=<機器人帳號>\n' > ~/.config/github-bot/config
   ```

   或改用 token 檔(放在倉庫外,不要 commit、不要貼進對話):

   ```bash
   mkdir -p ~/.config/github-bot && chmod 700 ~/.config/github-bot
   pbpaste > ~/.config/github-bot/token && chmod 600 ~/.config/github-bot/token   # 先複製 token
   printf 'TOKEN_FILE=~/.config/github-bot/token\n' > ~/.config/github-bot/config
   ```

4. 驗證:`bash ~/.claude/skills/github-bot/scripts/bot.sh identity` 印出機器人帳號名稱即成功。

模式優先序:`GH_USER` > `TOKEN_FILE` > App;環境變數 `GITHUB_BOT_GH_USER` / `GITHUB_BOT_TOKEN_FILE` / `GITHUB_BOT_APP_ID` 有設就直接決定模式,蓋過設定檔。只支援 github.com。PAT 是長效 token,外洩時到機器人帳號的設定頁 revoke 並重新產生。

建議 repo 的 `main` 設分支保護(Settings → Branches / Rulesets:Require a pull request),bot 只能走 PR。

## 用法(在要操作的 repo 目錄內執行;origin 不是可辨識的 github.com 網址時才加 `--repo owner/repo`,push 的 `--repo` 必須跟 origin 相同)

```bash
BOT=~/.claude/skills/github-bot/scripts/bot.sh
git switch -c <功能分支>
git add <檔案>
bash $BOT commit -m "訊息"                      # 以 bot 身分 commit(其他 git commit 參數照傳)
bash $BOT push <功能分支>                        # 推 HEAD 到遠端同名分支
bash $BOT pr --head <功能分支> --title "標題" --body-file <內文.md>   # 印出 PR 網址;--base 預設為預設分支
bash $BOT merge <號碼> --sha <review 過的完整 SHA>  # 合併;印出 merge commit SHA
GH_TOKEN=$(bash $BOT token) gh pr view <號碼>   # 其他 gh 操作需要時再借 token
```

- push 拒絕 `main`、`master`、repo 預設分支,也不支援 force;使用 Git LFS 的 repo 不支援(推送時停用 hooks,LFS 物件不會上傳);要改歷史先問使用者。
- curl 不讀 `~/.curlrc`(`-q`);token 經 stdin 給 curl;push 時放在 0700 暫存目錄裡的 0600 檔只給 credential helper 讀(結束、Ctrl-C、TERM、HUP 都會刪除),不進子程序環境變數、remote URL 或 `.git/config`。push 不讀全域 / 系統 git 設定(避免 `insteadOf` 改走 SSH 與個人金鑰)、HOME 換成空目錄(不讀 `~/.netrc` 的個人憑證)、停用 hooks;另外移除 `GIT_CONFIG`、`GIT_SSL_*`、`SSL_CERT_*`、`CURL_CA_BUNDLE`、proxy、trace 類環境變數;repo 的任何設定檔(local、worktree、include)有任何 `url.*`、`http.*`(`postBuffer`、`version`、`lowSpeedLimit`、`lowSpeedTime`、`maxRequests`、`minSessions` 除外)、`credential.*`、`remote.<網址>.*`(例如 pushurl)、`core.sshCommand` 設定會拒絕推送(這些能改寫網址、走 proxy、關 TLS 驗證或附加別的認證)。
- 合併前置條件見下方「自己 review 後合併」;bot 的權限(App 的 Contents: write、機器人帳號的 Write)本來就能合併,把關靠這個流程與 `--sha`。
- 錯誤 `取不到 <repo> 的 App installation(HTTP 404 ...)`:到 App 設定頁的 Install App 把該 repo 加進去。
- 換 App / 換電腦:只要重做第 4 步。私鑰外洩時到 App 設定頁刪掉該 key 並重新產生。

## 自己 review 後合併

1. `bash $BOT pr ...` 開 PR,記下 `HEAD_SHA=$(git rev-parse HEAD)`(必須等於 PR head)。
2. 用 `code-review` skill 審這個 PR(目標給 PR 號碼;等級用使用者上次指定的,沒有就用預設)。
3. 判定:
   - 有 `important`(這次變更造成的 bug)→ 修好、`bash $BOT commit` / `push`,更新 `HEAD_SHA=$(git rev-parse HEAD)` 後回到第 2 步重新 review(PR 不用重開;`bot.sh pr` 對已有 open PR 的分支也只會印出既有網址)。
   - 只剩 `nit` / `pre_existing` / 沒有發現 → 可以合併。`nit` 順手修的話一樣要重新 review。
   - 測試沒跑過或失敗、PR 有衝突、review 判斷需要使用者決定的產品問題 → 不合併,回報使用者。
4. `bash $BOT merge <號碼> --sha $HEAD_SHA`,預設 merge commit(跟 repo 既有「Merge pull request #n」一致)。
   - **bot 只自動合併沒有任何 CI 的 repo / commit**:PR head 或 base 分支最新 commit 的 `.github/workflows` 有任何檔案,或這兩個 commit 任一有 check run、commit status、GitHub Actions workflow run、其他 App(非 GitHub Actions)的 check suite(還沒有 run 也算;GitHub Actions 的空 suite 不算,repo 關掉 Actions 也不算),就拒絕並列出偵測到的項目——這時**不合併,回報使用者**,由使用者看過 CI 後自己合併。
   - 會等 15 秒(4 次查詢)確認沒有晚登記的外部 CI,合併前再確認一次;查詢失敗一律拒絕。
   - PR 非 open、head 不是該 SHA、有衝突、GitHub 回報 unstable / blocked / behind 也拒絕。
5. 回報使用者:PR 網址、review 結論(各發現怎麼處理)、merge commit SHA。合併後的功能分支、force-push、改歷史仍先問使用者。

`main` 的分支規則若要求 approval,作者不能核准自己的 PR,合併會被擋;要讓 bot 自己合併,規則只開「Require a pull request」、approvals 設 0。

## 自我測試

```bash
bash skills/github-bot/tests/run.sh    # 離線:本機產生 RSA 金鑰 + 假 GitHub API
```
