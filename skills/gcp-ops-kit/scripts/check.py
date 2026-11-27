"""環境檢查(依模式)。由 check.sh 呼叫。

check.sh yaml                 只檢查 ruby / python3 / node(kustomize 另需 kubectl)
check.sh review|plan|change [<專案>] [--scope iam,gcs,…](沒給專案用 GG_DEFAULT_PROJECT;scope 不含 gke / k8s 時不檢查 kubectl)   另檢查設定檔 / 金鑰權限、gcloud、gke-gcloud-auth-plugin、kubectl,啟用 SA 並確認能存取專案、列出 SA 角色
結束碼:0 可用、3 BLOCKED、2 用法錯誤
"""
import json
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gglib  # noqa: E402

WRITE_HINT = ("roles/owner", "roles/editor")


def main(argv):
    if not argv or argv[0] not in ("yaml", "review", "plan", "change"):
        gglib.die(__doc__, gglib.EXIT_USAGE)
    mode = argv[0]
    tools = ["ruby", "python3", "node"]
    missing = [t for t in tools if shutil.which(t) is None]
    if mode == "yaml":
        if missing:
            print(f"BLOCKED: 缺工具 {', '.join(missing)}", file=sys.stderr)
            return gglib.EXIT_BLOCKED
        print("yaml ok" + ("" if shutil.which("kubectl") else "(沒有 kubectl:kustomize 目錄會列為無法判定)"))
        return 0
    scope = "iam,network,gcs,sql,compute,gke,k8s"
    rest = list(argv[1:])
    if "--scope" in rest:
        i = rest.index("--scope")
        scope = rest[i + 1] if i + 1 < len(rest) else ""
        del rest[i:i + 2]
    project = rest[0] if rest else None
    if not project:
        try:
            project = gglib.load_config(require=False).get("GG_DEFAULT_PROJECT")
        except gglib.Blocked as e:
            print(f"BLOCKED: {e}", file=sys.stderr)
            return gglib.EXIT_BLOCKED
        if not project:
            print("BLOCKED: 沒給專案,設定檔也沒有 GG_DEFAULT_PROJECT", file=sys.stderr)
            return gglib.EXIT_BLOCKED
    try:
        gglib.check_project(project)
        need = ["gcloud"] + (["kubectl", "gke-gcloud-auth-plugin"] if {"gke", "k8s"} & set(scope.split(",")) or mode == "change" else [])
        missing += [t for t in need if shutil.which(t) is None]
        if missing:
            hint = []
            if "gcloud" in missing:
                hint.append("brew install --cask google-cloud-sdk")
            if "gke-gcloud-auth-plugin" in missing:
                hint.append("gcloud components install gke-gcloud-auth-plugin")
            raise gglib.Blocked(f"缺工具 {', '.join(missing)}(請使用者自己安裝:{';'.join(hint) or '見 SKILL.md'})")
        cfg = gglib.load_config(require=True)
        gglib.install_signal_handlers()
        os.makedirs(cfg["GG_REPORT_DIR"], 0o700, exist_ok=True)
        tmp = tempfile.mkdtemp(prefix=".check-", dir=cfg["GG_REPORT_DIR"])
        os.chmod(tmp, 0o700)
        try:
            with gglib.Session(cfg, tmp, project, "read") as s:
                r = s.gcloud(["projects", "describe", project, f"--project={project}", "--format=json", "--quiet"])
                if r.returncode != 0:
                    raise gglib.Blocked(f"SA 無法存取專案 {project}:" + gglib._short(r.stderr))
                r = s.gcloud(["projects", "get-iam-policy", project, f"--project={project}", "--format=json", "--quiet"])
                roles = []
                pol = None
                if r.returncode == 0:
                    try:
                        pol = json.loads(r.stdout or "{}")
                    except json.JSONDecodeError:
                        pol = None
                if pol is not None:
                    me = "serviceAccount:" + cfg["GG_SA"]
                    roles = sorted(b["role"] for b in pol.get("bindings") or [] if me in (b.get("members") or []))
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        print(f"{mode} ok project={project} sa={cfg['GG_SA']}")
        print("sa_roles=" + (",".join(roles) if roles else "（讀不到專案層級角色)"))
        if any(r in WRITE_HINT or r.endswith("admin") or r.endswith("Admin") for r in roles):
            print("資訊:此 SA 有寫入權限(使用者已知)")
        return 0
    except gglib.Blocked as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return gglib.EXIT_BLOCKED
    except gglib.Denied as e:
        print(f"DENIED: {e}", file=sys.stderr)
        return gglib.EXIT_DENIED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
