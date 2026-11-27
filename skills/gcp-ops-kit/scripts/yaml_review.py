"""k8s YAML 審查(不需 GCP、不需設定檔)。由 yaml-review.sh 呼叫。

yaml-review.sh <檔案或目錄>... [--label <名稱>]
- 目錄:遞迴收 *.yaml / *.yml;目錄含 kustomization.yaml 時改用 kubectl kustomize 展開(證據行號指向展開結果)
- 產出 <GG_REPORT_DIR>/yaml-<名稱>/<時間>-yaml/{findings.json, report.html, inventory/rendered/*}
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
    cfg = gglib.load_config(require=False)
    label = re.sub(r"[^a-z0-9-]+", "-", (label or os.path.basename(os.path.realpath(paths[0]))).lower()).strip("-")[:50] or "yaml"
    run = gglib.new_run(cfg, f"yaml-{label}"[:60], "yaml")
    files, kustom = gather(paths)
    meta = gglib.read_json(os.path.join(run, "meta.json"))
    meta.update({"inputs": [os.path.realpath(p) for p in paths], "files": files, "kustomize": kustom})
    gglib.write_json(os.path.join(run, "meta.json"), meta)
    undetermined = []
    rendered_docs = []
    for k in kustom:
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
                        docs.append({"obj": o, "file": f, "line": d["line"], "lines": {}})
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
