# xhe

我的 Claude Code skill 倉庫。每個 skill 放在 `skills/<名稱>/SKILL.md`。

| skill | 用途 |
|---|---|
| `agent-forge` | 造專業 agent、協調多個 agent 同時做事、依使用成果改進 agent |

## 安裝(全域連結)

把 skill 連到全域的 `~/.claude/skills`,所有專案都能用。連結要用絕對路徑:

```bash
mkdir -p ~/.claude/skills
ln -s "$(pwd)/skills/agent-forge" ~/.claude/skills/agent-forge   # 在倉庫根目錄執行
```

不要再在專案的 `.claude/skills/` 建同名連結,否則會出現兩份 `agent-forge`。

## 更新與開發

- 直接改 `skills/agent-forge/` 底下的檔案。全域連結指向這個工作目錄,所以所有專案用的都是**目前切到的分支**,包含還沒合併的修改。
- playbook、角色、範本在下一個任務就會讀到新版;改到 `SKILL.md` 本身或新增 skill,要開新對話。
- 正式修改走分支 → PR → 合併進 `main`;平常使用時把倉庫留在 `main`。
