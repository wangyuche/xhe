---
name: github-bot
description: 用 GitHub App 機器人(例如 xhe-bot[bot])身分 commit、push 功能分支、開 PR。預設用 App 私鑰簽 JWT 換短效 installation token(1 小時、只限該 repo);也支援另開機器人帳號用 classic PAT。主 agent 要把變更推上 GitHub 並開 PR,或使用者說「用 bot commit / push」「bot 開 PR」時使用。不推 main / master / 預設分支,不 force-push,不 merge。
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

### 替代方案:機器人帳號 + PAT(machine user)

不建 App,改用另一個 GitHub 帳號當機器人(commit 作者顯示該帳號名稱,沒有 `[bot]`):

1. 用主帳號到 repo → Settings → Collaborators → 邀請機器人帳號(Write 權限),再登入機器人帳號接受邀請。
2. 機器人帳號產生 **classic** PAT(Settings → Developer settings → Tokens (classic)),scope 勾 `public_repo`(private repo 要勾 `repo`),設到期日。fine-grained PAT 無法存取「別人個人帳號底下」的 repo,所以要用 classic。
3. **建議:token 放 gh(macOS 鑰匙圈,磁碟上沒有明文)**。gh 可同時登入多個帳號,不必切換,bot 用 `gh auth token --user` 取機器人的 token,gh 平常仍停在主帳號:

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

設了 `TOKEN_FILE` 就優先走 PAT 模式。PAT 是長效 token,外洩時到機器人帳號的設定頁 revoke 並重新產生。

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
