---
name: github-bot
description: 用 GitHub App 機器人(例如 xhe-bot[bot])身分 commit、push 功能分支、開 PR。token 是 App 私鑰簽 JWT 換來的短效 installation token(1 小時、只限該 repo),不用個人帳號密碼或 PAT。主 agent 要把變更推上 GitHub 並開 PR,或使用者說「用 bot commit / push」「bot 開 PR」時使用。不推 main / master / 預設分支,不 force-push,不 merge。
---

# github-bot

腳本:`scripts/bot.sh`(只需 bash、openssl、curl、jq、git)。

## 一次性設定(使用者在瀏覽器做)

1. 建立 App:<https://github.com/settings/apps/new>
   - GitHub App name:例如 `xhe-bot`(commit 作者會顯示 `xhe-bot[bot]`)
   - Homepage URL:repo 網址即可
   - Webhook:取消勾選 **Active**
   - Repository permissions:**Contents: Read and write**、**Pull requests: Read and write**(Metadata: Read 會自動帶入),其餘不要
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

建議 repo 的 `main` 設分支保護(Settings → Branches / Rulesets:Require a pull request),bot 只能走 PR。

## 用法(在 repo 內執行;其他 repo 前面加 `--repo owner/repo`)

```bash
BOT=~/.claude/skills/github-bot/scripts/bot.sh
git switch -c <功能分支>
git add <檔案>
bash $BOT commit -m "訊息"                      # 以 bot 身分 commit(其他 git commit 參數照傳)
bash $BOT push <功能分支>                        # 推 HEAD 到遠端同名分支
bash $BOT pr --head <功能分支> --title "標題" --body-file <內文.md>   # 印出 PR 網址;--base 預設為預設分支
GH_TOKEN=$(bash $BOT token) gh pr view <號碼>   # 其他 gh 操作需要時再借 token
```

- push 拒絕 `main`、`master`、repo 預設分支,也不支援 force;要改歷史先問使用者。
- token 只透過 stdin / 環境變數傳給 curl、git,不寫進 remote URL 或 `.git/config`。
- 合併 PR 仍依專案流程(驗證通過後由主 agent / 使用者處理),bot 預設權限不夠也不該自己 merge。
- 錯誤 `App 沒有安裝在 ...`:到 App 設定頁的 Install App 把該 repo 加進去。
- 換 App / 換電腦:只要重做第 4 步。私鑰外洩時到 App 設定頁刪掉該 key 並重新產生。

## 自我測試

```bash
bash skills/github-bot/tests/run.sh    # 離線:本機產生 RSA 金鑰 + 假 GitHub API
```
