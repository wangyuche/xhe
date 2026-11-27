"""唯讀盤點 + 規則 + 報告(審查 / 計畫模式的第一步)。由 collect.sh 呼叫。

collect.sh [<專案>] [--mode review|plan] [--scope iam,network,gcs,sql,compute,gke,k8s] [--clusters a,b] [--prev <上次 run 目錄>]
stdout 最後一行:run=<run 目錄>
結束碼:0 完成(可能有無法判定)、3 BLOCKED、4 指令被拒絕(kit 錯誤)
"""
import json
import os
import shutil
import subprocess
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.realpath(__file__)))

import gglib
import gcp_rules
import k8s_rules

AREAS = ["iam", "network", "gcs", "sql", "compute", "gke", "k8s"]
K8S_KINDS = ["namespaces", "pods", "deployments", "daemonsets", "statefulsets", "replicasets", "jobs", "cronjobs",
             "services", "ingresses", "networkpolicies", "serviceaccounts", "roles", "rolebindings",
             "clusterroles", "clusterrolebindings", "configmaps"]


def need_tools(mode, areas=AREAS):
    tools = ["gcloud", "ruby", "python3", "node"] + (["kubectl", "gke-gcloud-auth-plugin"] if {"gke", "k8s"} & set(areas) else [])
    missing = [t for t in tools if shutil.which(t) is None]
    if missing:
        hint = []
        if "gcloud" in missing:
            hint.append("brew install --cask google-cloud-sdk")
        if "gke-gcloud-auth-plugin" in missing:
            hint.append("gcloud components install gke-gcloud-auth-plugin")
        raise gglib.Blocked(f"缺工具:{', '.join(missing)}(請使用者自己安裝:{';'.join(hint) or '見 SKILL.md'})")


class Collector:
    def __init__(self, s, run, project, areas, clusters):
        self.s, self.run, self.project, self.areas, self.clusters = s, run, project, areas, clusters
        self.inv = os.path.join(run, "inventory")
        self.undetermined = []

    def p(self):
        return f"--project={self.project}"

    def save(self, name, obj):
        gglib.write_json(os.path.join(self.inv, name), gglib.redact(obj))

    def g(self, area, name, args):
        r = self.s.gcloud(args + [self.p(), "--format=json", "--quiet"])
        if r.returncode != 0:
            self.undetermined.append({"area": area, "item": name, "error": gglib._short(r.stderr, 400)})
            return None
        try:
            obj = json.loads(r.stdout or "null")
        except json.JSONDecodeError:
            self.undetermined.append({"area": area, "item": name, "error": "輸出不是 JSON"})
            return None
        self.save(name, obj)
        return gglib.read_json(os.path.join(self.inv, name))

    def run_all(self):
        proj = self.g("project", "project.json", ["projects", "describe", self.project])
        if proj is None:
            raise gglib.Blocked(f"SA 無法存取專案 {self.project}:" + self.undetermined[-1]["error"])
        a = self.areas
        if "iam" in a:
            self.g("iam", "iam-policy.json", ["projects", "get-iam-policy", self.project])
            sas = self.g("iam", "service-accounts.json", ["iam", "service-accounts", "list"]) or []
            for sa in sas:
                em = sa.get("email")
                if em:
                    self.g("iam", os.path.join("sa-keys", f"{em}.json"),
                           ["iam", "service-accounts", "keys", "list", f"--iam-account={em}", "--managed-by=user"])
        self.g("project", "services.json", ["services", "list", "--enabled"])
        if "network" in a:
            for nm, args in (("networks.json", ["compute", "networks", "list"]),
                             ("subnets.json", ["compute", "networks", "subnets", "list"]),
                             ("firewalls.json", ["compute", "firewall-rules", "list"]),
                             ("addresses.json", ["compute", "addresses", "list"]),
                             ("routers.json", ["compute", "routers", "list"])):
                self.g("network", nm, args)
        if "compute" in a:
            self.g("compute", "project-info.json", ["compute", "project-info", "describe"])
            self.g("compute", "instances.json", ["compute", "instances", "list"])
        if "gcs" in a:
            bks = self.g("gcs", "buckets.json", ["storage", "buckets", "list"]) or []
            for b in bks:
                name = b.get("name") or (b.get("storage_url") or "").replace("gs://", "").rstrip("/")
                if name:
                    self.g("gcs", os.path.join("bucket-iam", f"{name}.json"),
                           ["storage", "buckets", "get-iam-policy", f"gs://{name}"])
        if "sql" in a:
            self.g("sql", "sql.json", ["sql", "instances", "list"])
        clusters = []
        if "gke" in a or "k8s" in a:
            clusters = self.g("gke", "clusters.json", ["container", "clusters", "list"]) or []
            if self.clusters:
                found = {c.get("name") for c in clusters}
                for miss in sorted(set(self.clusters) - found):
                    self.undetermined.append({"area": "gke", "item": miss, "error": "找不到這個叢集(名稱打錯或不在本專案)"})
                clusters = [c for c in clusters if c.get("name") in self.clusters]
            for c in clusters:
                self.g("gke", os.path.join("nodepools", f"{c['location']}_{c['name']}.json"),
                       ["container", "node-pools", "list", f"--cluster={c['name']}", f"--location={c['location']}"])
        if "k8s" in a:
            for c in clusters:
                self.k8s(c)
        gglib.write_json(os.path.join(self.inv, "undetermined.json"), self.undetermined)

    def k8s(self, c):
        r, ctx = self.s.get_credentials(c["name"], c["location"])
        if r.returncode != 0:
            self.undetermined.append({"area": "k8s", "item": c["name"], "error": gglib._short(r.stderr, 400)})
            return
        d = os.path.join("k8s", f"{c['location']}_{c['name']}")  # 叢集名稱只在同一位置內唯一
        for kind in K8S_KINDS:
            r = self.s.kubectl(ctx, ["get", kind, "-A", "-o", "json", "--request-timeout=60s"])
            if r.returncode != 0:
                self.undetermined.append({"area": "k8s", "item": f"{c['name']}/{kind}", "error": gglib._short(r.stderr, 300)})
                continue
            try:
                items = (json.loads(r.stdout) or {}).get("items") or []
            except json.JSONDecodeError:
                self.undetermined.append({"area": "k8s", "item": f"{c['name']}/{kind}", "error": "輸出不是 JSON"})
                continue
            for it in items:
                (it.get("metadata") or {}).pop("managedFields", None)
            self.save(os.path.join(d, f"{kind}.json"), {"context": ctx, "items": items})
        r = self.s.kubectl(ctx, ["get", "secrets", "-A", "-o=go-template=" + gglib.SECRET_TMPL, "--request-timeout=60s"])
        if r.returncode != 0:
            self.undetermined.append({"area": "k8s", "item": f"{c['name']}/secrets", "error": gglib._short(r.stderr, 300)})
        else:
            rows = []
            for line in r.stdout.splitlines():
                parts = line.split("\t")
                if len(parts) >= 4:
                    rows.append({"namespace": parts[0], "name": parts[1], "type": parts[2],
                                 "keys": [k for k in parts[3].split(",") if k]})
            self.save(os.path.join(d, "secrets.json"), {"context": ctx, "items": rows})


def k8s_docs(inv):
    docs = []
    root = os.path.join(inv, "k8s")
    if not os.path.isdir(root):
        return docs
    for cl in sorted(os.listdir(root)):
        for fn in sorted(os.listdir(os.path.join(root, cl))):
            if fn == "secrets.json" or not fn.endswith(".json"):
                continue
            data = gglib.read_json(os.path.join(root, cl, fn), {}) or {}
            kind_name = {"networkpolicies": "NetworkPolicy"}.get(fn[:-5])
            for i, it in enumerate(data.get("items") or []):
                if kind_name and "kind" not in it:
                    it["kind"] = kind_name
                docs.append({"obj": it, "file": f"inventory/k8s/{cl}/{fn}", "index": i, "context": data.get("context")})
    return docs


def analyze(run, cfg):
    inv = os.path.join(run, "inventory")
    pol = gglib.read_json(os.path.join(inv, "iam-policy.json"), {}) or {}
    me = "serviceAccount:" + (cfg.get("GG_SA") or "")
    meta = gglib.read_json(os.path.join(run, "meta.json"), {})
    meta["sa_roles"] = sorted(b.get("role") for b in pol.get("bindings") or [] if me in (b.get("members") or []))
    gglib.write_json(os.path.join(run, "meta.json"), meta)
    findings = gcp_rules.scan(inv, cfg.get("GG_SA"))
    by_ctx = {}
    for d in k8s_docs(inv):
        by_ctx.setdefault(d.get("context"), []).append(d)
    for ctx in sorted(by_ctx, key=str):  # 每個叢集分開掃,namespace 不會跨叢集混在一起
        findings += k8s_rules.scan(by_ctx[ctx], live=True)
    gglib.write_json(os.path.join(run, "findings.json"), findings)
    return findings


def render(run):
    r = subprocess.run(["node", os.path.join(gglib.KIT, "scripts", "render.mjs"), run], capture_output=True, text=True)
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    return r.returncode


def main(argv):
    if not argv or argv[0].startswith("-"):
        try:
            default = gglib.load_config(require=False).get("GG_DEFAULT_PROJECT")
        except gglib.Blocked as e:
            print(f"BLOCKED: {e}", file=sys.stderr)
            return gglib.EXIT_BLOCKED
        if not default:
            print("BLOCKED: 沒給專案,設定檔也沒有 GG_DEFAULT_PROJECT", file=sys.stderr)
            return gglib.EXIT_BLOCKED
        argv = [default] + list(argv)
    project = argv[0]
    opts = {"--mode": "review", "--scope": ",".join(AREAS), "--clusters": "", "--prev": ""}
    it = iter(argv[1:])
    for a in it:
        if a in opts:
            opts[a] = next(it, "")
        else:
            gglib.die(f"未知參數 {a}", gglib.EXIT_USAGE)
    areas = [x for x in opts["--scope"].split(",") if x]
    if any(x not in AREAS for x in areas) or opts["--mode"] not in ("review", "plan"):
        gglib.die("--scope / --mode 不對", gglib.EXIT_USAGE)
    try:
        cfg = gglib.load_config(require=True)
        gglib.check_project(project)
        need_tools(opts["--mode"], areas)
        run = gglib.new_run(cfg, project, opts["--mode"])
        meta = gglib.read_json(os.path.join(run, "meta.json"))
        prev = None
        if opts["--prev"]:
            prev = os.path.realpath(opts["--prev"])
            if not prev.startswith(os.path.realpath(cfg["GG_REPORT_DIR"]) + os.sep) or not os.path.exists(os.path.join(prev, "meta.json")):
                raise gglib.Blocked(f"--prev 要是 GG_REPORT_DIR 底下的 run 目錄:{opts['--prev']}")
        meta.update({"areas": areas, "clusters": opts["--clusters"], "prev": prev})
        gglib.write_json(os.path.join(run, "meta.json"), meta)
        with gglib.Session(cfg, run, project, "read") as s:
            Collector(s, run, project, areas, [c for c in opts["--clusters"].split(",") if c]).run_all()
        analyze(run, cfg)
        if not os.path.exists(os.path.join(run, "plan.json")):
            gglib.write_json(os.path.join(run, "plan.json"), {"project": project, "items": [], "source_run": run})
        rc = render(run)
        print(f"run={run}")
        return 0 if rc == 0 else 1
    except gglib.Blocked as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return gglib.EXIT_BLOCKED
    except gglib.Denied as e:
        print(f"DENIED: {e}", file=sys.stderr)
        return gglib.EXIT_DENIED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
