"""gcp-guardian 的 PreToolUse hook(Bash / Read / Write / Edit)。

stdin:Claude Code hook JSON({"tool_name", "tool_input", "cwd", ...})
允許 → 結束碼 0;拒絕 → 結束碼 2,原因寫 stderr(會回給 agent)。
也可:python3 guard.py --test '<bash 指令>'  → 印 allow / deny 與原因(selftest 用)
"""
import json
import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gglib  # noqa: E402

SCRIPTS = os.path.join(gglib.KIT, "scripts")
ENTRIES = {"check.sh", "collect.sh", "plan.py", "change.sh", "render.mjs", "yaml-review.sh", "selftest.sh"}
INTERP = {".sh": {"bash"}, ".py": {"python3"}, ".mjs": {"node"}}
FORBIDDEN_CHARS = set(";&|`$<>()\n\r\\*?[]{}~!#")
READONLY_CMDS = {"ls", "cat", "head", "tail", "wc", "grep", "shasum", "stat", "date", "pwd", "find", "diff"}
FIND_DENY = {"-exec", "-execdir", "-delete", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"}
CLOUD_WORDS = ("gcloud", "kubectl", "cloudsdk", "kubeconfig", "gke-gcloud-auth-plugin", "gsutil", "bq ", "terraform",
               "curl", "wget", "googleapis")
WRITABLE_NAMES = {"manual.json", "plan.input.json"}


def protected_paths(cfg):
    home = os.path.expanduser("~")
    ps = [os.path.dirname(gglib.config_path()), os.path.join(home, ".config", "gcloud"), os.path.join(home, ".kube")]
    if cfg.get("GG_SA_KEY_FILE"):
        ps.append(cfg["GG_SA_KEY_FILE"])
    return [os.path.realpath(p).lower() for p in ps]


def _norm(path, cwd):
    # macOS 預設檔案系統不分大小寫:一律轉小寫比較
    return os.path.realpath(os.path.join(cwd, os.path.expanduser(path))).lower()


def is_protected(path, cfg, cwd, ancestor=True, rollback_ancestor=True):
    """path 本身或其下層是受保護路徑;ancestor=True 時,path 是受保護路徑的上層目錄也算(遞迴工具可讀到)。"""
    p = _norm(path, cwd)
    prot = protected_paths(cfg)
    for q in prot:
        if p == q or p.startswith(q + os.sep):
            return True
        if ancestor and (q.startswith(p.rstrip(os.sep) + os.sep) or p == os.sep):
            return True
    parts = p.split(os.sep)
    rd = os.path.realpath(cfg["GG_REPORT_DIR"]).lower()
    if p.startswith(rd + os.sep) and ("gcloud" in parts or parts[-1] == "kubeconfig" or parts[-1].endswith(".rollback.json")):
        return True
    if ancestor and (p == rd or p.startswith(rd + os.sep) or rd.startswith(p.rstrip(os.sep) + os.sep)):
        # 報告目錄(或其上層):執行中的 run 會有 gcloud/ 憑證快取與 kubeconfig,遞迴工具不可碰
        if _live_creds_under(rd if rd.startswith(p.rstrip(os.sep) + os.sep) else p, rollback_ancestor):
            return True
    return False


def _live_creds_under(top, rollback=True):
    try:
        for root, dirs, files in os.walk(top):
            low = [d.lower() for d in dirs] + [f.lower() for f in files]
            if "gcloud" in low or "kubeconfig" in low or (rollback and any(x.endswith(".rollback.json") for x in low)):
                return True
            dirs[:] = [d for d in dirs if not d.startswith(".lock")]
    except OSError:
        return True
    return False


def arg_paths(tok):
    """從參數取出可能的路徑:一般參數、--opt=值、-f/路徑。"""
    if not tok.startswith("-"):
        return [tok]
    if "=" in tok:
        return [tok.split("=", 1)[1]]
    if tok.startswith("--"):
        return []
    # 短旗標可能直接黏著路徑(-f../x、-f/abs):旗標字母之後的每一段都當成候選路徑
    return [tok[j:] for j in range(2, len(tok))]


def check_bash(cmd, cfg, cwd):
    if not cmd.strip():
        return "空指令"
    bad = sorted(c for c in set(cmd) if c in FORBIDDEN_CHARS)
    if bad:
        return f"指令不可含 {''.join(bad)!r}(不可串接、轉向、展開、萬用字元);一次只跑一個 kit 入口腳本"
    try:
        toks = shlex.split(cmd)
    except ValueError as e:
        return f"無法解析指令:{e}"
    if not toks:
        return "空指令"
    i = 0
    if toks[0] in ("bash", "python3", "node") and len(toks) > 1:
        i = 1
    first = toks[i]
    if "/" in first:
        real = os.path.realpath(os.path.join(cwd, os.path.expanduser(first)))
        base = os.path.basename(real)
        if os.path.dirname(real) == os.path.realpath(SCRIPTS) and base in ENTRIES:
            if i == 1 and toks[0] not in INTERP[os.path.splitext(base)[1]]:
                return f"{base} 不能用 {toks[0]} 執行"
            if any(t.startswith("-") and t in ("-c", "-e", "-i", "--eval") for t in toks[:i]):
                return "不允許直譯器旗標"
            for t in toks[i + 1:]:
                for pth in arg_paths(t):
                    # 入口腳本自己讀 run 目錄(不會印出 rollback.json 內容),只擋憑證快取
                    if pth and is_protected(pth, cfg, cwd, rollback_ancestor=False):
                        return f"參數指向受保護路徑(或其上層目錄):{t}"
            return None
        return f"只允許 gcp-ops-kit 的入口腳本({', '.join(sorted(ENTRIES))}),不允許 {first}"
    low = cmd.lower()
    for w in CLOUD_WORDS:
        if w in low:
            return f"不可直接呼叫 {w.strip()};所有雲端操作都要透過 kit 入口腳本"
    if i == 1:
        return "直譯器只能執行 kit 入口腳本"
    if first not in READONLY_CMDS:
        return f"只允許 kit 入口腳本與唯讀指令({', '.join(sorted(READONLY_CMDS))})"
    if first == "find" and any(t in FIND_DENY for t in toks):
        return "find 不允許 -exec / -delete 等動作"
    # 沒寫路徑時遞迴工具會掃 cwd:把 cwd 當成隱含路徑一起檢查
    gtoks = toks[1:]
    d_recurse = any((t == "-d" and i + 1 < len(gtoks) and gtoks[i + 1] == "recurse") or t.startswith("-drecurse")
                    or (t.startswith("-") and not t.startswith("--") and "d" in t and t.endswith("recurse"))
                    for i, t in enumerate(gtoks))
    recursive = (first in ("grep", "diff") and (d_recurse or any(t in ("-r", "-R", "--recursive", "--dereference-recursive")
                                                   or (t.startswith("-") and not t.startswith("--") and ("r" in t or "R" in t))
                                                   or t.startswith("--directories") for t in gtoks))) \
        or (first == "find" and (len(toks) == 1 or toks[1].startswith("-"))) \
        or (first == "ls" and any(x.startswith("-") and not x.startswith("--") and "R" in x for x in toks[1:]) and not any(not x.startswith("-") for x in toks[1:]))
    if recursive and is_protected(cwd, cfg, cwd, ancestor=True):
        return f"遞迴搜尋目前目錄({cwd})會碰到受保護路徑;請寫明不含受保護路徑的絕對路徑"
    for t in toks[1:]:
        for pth in arg_paths(t):
            ls_recursive = first == "ls" and any(x.startswith("-") and not x.startswith("--") and "R" in x or x == "--recursive" for x in toks[1:])
            if pth and is_protected(pth, cfg, cwd, ancestor=ls_recursive or first not in ("ls", "stat", "pwd", "date")):
                return f"不可讀受保護路徑(或其上層目錄):{t}"
    return None


def check_path_tool(tool, inp, cfg, cwd):
    if tool in ("Grep", "Glob"):
        base = inp.get("path") or cwd
        pats = [inp.get("pattern") if tool == "Glob" else None, inp.get("glob")]
        roots = [base] + [x.split("*")[0].split("{")[0] for x in pats if x and x.startswith(("/", "~"))]
        for r in roots:
            if r and is_protected(r, cfg, cwd, ancestor=True):
                return f"搜尋範圍包含受保護路徑:{r}"
        return None
    p = inp.get("file_path") or inp.get("path") or inp.get("notebook_path") or ""
    if not p:
        return None
    if is_protected(p, cfg, cwd, ancestor=False):
        return f"不可存取受保護路徑:{p}"
    if tool in ("Write", "Edit", "MultiEdit", "NotebookEdit"):
        real = os.path.realpath(os.path.join(cwd, p))
        rd = os.path.realpath(cfg["GG_REPORT_DIR"])
        run = os.path.dirname(real)
        if not (real.startswith(rd + os.sep) and os.path.basename(real) in WRITABLE_NAMES
                and os.path.exists(os.path.join(run, "meta.json"))):
            return "只能寫 run 目錄裡的 manual.json 或 plan.input.json"
    return None


def decide(payload):
    cfg = gglib.load_config(require=False)
    tool = payload.get("tool_name", "")
    inp = payload.get("tool_input") or {}
    cwd = payload.get("cwd") or os.getcwd()
    if tool == "Bash":
        return check_bash(inp.get("command", ""), cfg, cwd)
    if tool in ("Read", "Write", "Edit", "MultiEdit", "NotebookEdit", "Grep", "Glob"):
        return check_path_tool(tool, inp, cfg, cwd)
    return None


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--test":
        why = decide({"tool_name": "Bash", "tool_input": {"command": sys.argv[2]}, "cwd": os.getcwd()})
        print("deny\t" + why if why else "allow")
        return 0
    try:
        payload = json.load(sys.stdin)
    except Exception:
        print("gcp-guardian guard:讀不到 hook 輸入,拒絕", file=sys.stderr)
        return 2
    try:
        why = decide(payload)
    except Exception as e:  # 守門失敗一律拒絕
        why = f"守門檢查出錯:{e}"
    if why:
        print(f"gcp-guardian guard 拒絕:{why}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
