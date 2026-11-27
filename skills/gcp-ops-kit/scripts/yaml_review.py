"""k8s YAML 審查(不需 GCP、不需設定檔)。由 yaml-review.sh 呼叫。

yaml-review.sh <檔案或目錄>... [--label <名稱>]
- 目錄:遞迴收 *.yaml / *.yml;目錄含 kustomization.yaml 時改用 kubectl kustomize 展開(證據行號指向展開結果)
- 產出 <GG_REPORT_DIR>/_yaml/<名稱>/<時間>-yaml/{findings.json, report.html, inventory/rendered/*}
stdout 最後一行:run=<run 目錄>
"""
import json
import os
import re
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gglib  # noqa: E402
import k8s_rules  # noqa: E402

SKIP_DIRS = {".git", "node_modules", "vendor", ".terraform"}


REMOTE_RE = re.compile(r"(?m)^\s*-?\s*(?:\w+:\s*)?['\"]?((?:https?|git|ssh)://\S+|git@\S+|github\.com/\S+|gitlab\.com/\S+|bitbucket\.org/\S+)")


def _remote_refs(kdir):
    """kustomization(含它引用的本機 base)裡的遠端資源;有的話不展開(YAML 審查不連網)。"""
    refs, seen, todo = [], set(), [kdir]
    while todo:
        d = os.path.realpath(todo.pop())
        if d in seen:
            continue
        seen.add(d)
        for fn in ("kustomization.yaml", "kustomization.yml", "Kustomization"):
            p = os.path.join(d, fn)
            if os.path.isfile(p):
                r = subprocess.run(["ruby", os.path.join(gglib.KIT, "scripts", "yaml2json.rb"), p], capture_output=True, text=True, timeout=60)
                if r.returncode != 0:
                    refs.append(f"{p}(無法解析)")
                    continue
                for doc in json.loads(r.stdout or "[]"):
                    k = doc.get("obj") or {}
                    if not isinstance(k, dict):
                        continue
                    if k.get("helmCharts") or k.get("helmChartInflationGenerator"):
                        refs.append("helmCharts(會下載 chart)")
                    for fld in ("resources", "bases", "components", "crds", "configurations", "transformers", "generators", "validators"):
                        for v in k.get(fld) or []:
                            if not isinstance(v, str):
                                continue
                            local = os.path.join(d, v)
                            if os.path.isdir(local):
                                todo.append(local)
                            elif not os.path.isfile(local):
                                refs.append(v)  # 白名單:只有本機存在的檔案 / 目錄才展開,其餘視為遠端
    return refs


def gather(paths):
    files, kustom = [], []
    for p in paths:
        p = os.path.realpath(p)
        if os.path.isfile(p):
            files.append(p)
            continue
        if not os.path.isdir(p):
            gglib.die(f"找不到 {p}", gglib.EXIT_USAGE)
        for root, dirs, fns in os.walk(p):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            if any(f in fns for f in ("kustomization.yaml", "kustomization.yml", "Kustomization")):
                kustom.append(root)
                dirs[:] = []
                continue
            for f in sorted(fns):
                if f.endswith((".yaml", ".yml")):
                    files.append(os.path.join(root, f))
    return sorted(set(files)), kustom


def main(argv):
    label, paths = None, []
    it = iter(argv)
    for a in it:
        if a == "--label":
            label = next(it, None)
        else:
            paths.append(a)
    if not paths:
        gglib.die(__doc__, gglib.EXIT_USAGE)
    for t in ("ruby", "node"):
        if shutil.which(t) is None:
            print(f"BLOCKED: 缺工具 {t}", file=sys.stderr)
            return gglib.EXIT_BLOCKED
    try:
        cfg = gglib.load_config(require=False)
    except gglib.Blocked as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return gglib.EXIT_BLOCKED
    label = re.sub(r"[^a-z0-9-]+", "-", (label or os.path.basename(os.path.realpath(paths[0]))).lower()).strip("-")[:50] or "yaml"
    if label in ("gcloud", "kubeconfig", "home"):
        label = "yaml-" + label  # 避免和 run 內的憑證快取名稱相同(guard 會擋)
    files, kustom = gather(paths)  # 先確認輸入存在,再建立 run 目錄
    run = gglib.new_run(cfg, os.path.join("_yaml", label), "yaml")  # 與 GCP 專案 ID 分開的命名空間
    meta = gglib.read_json(os.path.join(run, "meta.json"))
    meta.update({"inputs": [os.path.realpath(p) for p in paths], "files": files, "kustomize": kustom})
    gglib.write_json(os.path.join(run, "meta.json"), meta)
    undetermined = []
    rendered_docs = []
    for k in kustom:
        remote = _remote_refs(k)
        if remote:
            undetermined.append({"area": "yaml", "item": k, "error": f"引用遠端資源,不連網展開:{', '.join(remote[:3])}"})
            continue
        if shutil.which("kubectl") is None:
            undetermined.append({"area": "yaml", "item": k, "error": "kustomize 目錄需要 kubectl"})
            continue
        r = subprocess.run(["kubectl", "kustomize", k], capture_output=True, text=True, timeout=120,
                           env={"PATH": os.environ.get("PATH", ""), "HOME": os.environ.get("HOME", ""),
                                "KUBECONFIG": os.devnull})
        if r.returncode != 0:
            undetermined.append({"area": "yaml", "item": k, "error": gglib._short(r.stderr, 400)})
            continue
        r2 = subprocess.run(["ruby", os.path.join(gglib.KIT, "scripts", "yaml2json.rb"), "-"], input=r.stdout,
                            capture_output=True, text=True, timeout=120)
        if r2.returncode != 0:
            undetermined.append({"area": "yaml", "item": k, "error": gglib._short(r2.stderr, 400)})
            continue
        rel = re.sub(r"[^A-Za-z0-9._-]+", "_", k.strip("/")) + ".json"
        out = os.path.join(run, "inventory", "rendered", rel)
        kdocs = []
        for d in json.loads(r2.stdout or "[]"):
            d["obj"] = gglib.redact(d["obj"])  # 寫檔前遮蔽(secretGenerator 等)
            d["file"] = f"{k}(kustomize 展開結果)"
            kdocs.append(d)
        gglib.write_json(out, [d["obj"] for d in kdocs])
        rendered_docs.extend(kdocs)
    docs = []
    for f in files:
        r = subprocess.run(["ruby", os.path.join(gglib.KIT, "scripts", "yaml2json.rb"), f],
                           capture_output=True, text=True, timeout=120)
        if r.returncode != 0:
            undetermined.append({"area": "yaml", "item": f, "error": gglib._short(r.stderr, 400)})
            continue
        for d in json.loads(r.stdout or "[]"):
            if isinstance(d.get("obj"), dict) and d["obj"].get("kind"):
                if d["obj"].get("kind") == "List":
                    for i, o in enumerate(d["obj"].get("items") or []):
                        if not isinstance(o, dict):
                            undetermined.append({"area": "yaml", "item": f"{f} items[{i}]", "error": "List 的項目不是物件,略過"})
                            continue
                        pre = f"/items/{i}"
                        sub = {(k[len(pre):] or "/"): v for k, v in d["lines"].items() if k == pre or k.startswith(pre + "/")}
                        docs.append({"obj": o, "file": f, "line": sub.get("/", d["line"]), "lines": sub})
                    continue
                docs.append(d)
    docs.extend(d for d in rendered_docs if isinstance(d.get("obj"), dict) and d["obj"].get("kind"))
    findings = k8s_rules.scan(docs, live=False)
    gglib.write_json(os.path.join(run, "findings.json"), findings)
    gglib.write_json(os.path.join(run, "inventory", "undetermined.json"), undetermined)
    gglib.write_json(os.path.join(run, "plan.json"), {"project": None, "items": [], "source_run": run})
    meta["documents"] = len(docs)
    gglib.write_json(os.path.join(run, "meta.json"), meta)
    r = subprocess.run(["node", os.path.join(gglib.KIT, "scripts", "render.mjs"), run])
    print(f"documents={len(docs)} findings={len(findings)} undetermined={len(undetermined)}")
    print(f"run={run}")
    return 0 if r.returncode == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
