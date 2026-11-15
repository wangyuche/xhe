# xhe

我的 Claude Code skill 倉庫。每個 skill 放在 `skills/<名稱>/SKILL.md`。

| skill | 用途 |
|---|---|
| `agent-forge` | 造專業 agent、協調多個 agent 同時做事、依使用成果改進 agent |

## 安裝到所有 sbx 沙盒

在 host 上執行(`sbx skills` 目前是實驗性功能):

```bash
sbx skills add wangyuche/xhe --skill agent-forge   # 第一次安裝
sbx skills ls                                      # 確認有裝到
```

skill 會裝進 sbx 的共用倉庫,每個沙盒啟動時以唯讀方式掛到 `~/.claude/skills`。

## 更新

1. 在分支上修改,開 PR,審查後合併進 `main`。
2. 在 host 上執行 `sbx skills update agent-forge`。
3. 沙盒裡:playbook、角色、範本在下一個任務就會讀到新版;改到 `SKILL.md` 本身或新增 skill,要開新對話。

## 開發

- 直接改 `skills/agent-forge/` 底下的檔案。
- 在 xhe 沙盒裡想用開發中的版本測試,建立本機連結(已在 `.gitignore`,不會進 git):

  ```bash
  ln -s ../../skills/agent-forge .claude/skills/agent-forge
  ```

## 安全

- 沙盒維持預設的唯讀模式。**不要建立 `--skills=readwrite` 的沙盒**:一個可寫的沙盒能改掉所有沙盒用的 skill。
- 只從 GitHub 安裝審查過的內容。建議在 GitHub 開啟 `main` 的分支保護,要求 PR 才能合併。
- 不想讓某個沙盒用共用 skill,建立時加 `--skills=off`。
