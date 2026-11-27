"""計畫與變更共用:快照、dry-run、precondition(不可單獨執行)。"""
import json
import os
import re
import subprocess

import gglib
import ggchange
import k8s_rules

CTX_RE = re.compile(r"^gke_([a-z][a-z0-9-]{4,28}[a-z0-9])_([a-z0-9-]+)_([A-Za-z0-9._-]+)$")
MANIFEST_TOKEN = "--filename=<manifest>"
PATCH_TOKEN = "--patch-file=<patch>"


def materialize(item, run):
    """把 plan 裡的 <manifest> / <patch> 占位換成 run 目錄的實際檔案。回傳實際 argv。"""
    argv = list(item["command"])
    for a in argv:
        if (a.startswith("--filename") and a != MANIFEST_TOKEN) or (a.startswith("--patch-file") and a != PATCH_TOKEN):
            raise gglib.Blocked(f"{a.split('=')[0]} 只能寫占位 {MANIFEST_TOKEN} / {PATCH_TOKEN}(內容放 manifest / patch 欄位,才會被 sha256 涵蓋)")
    if MANIFEST_TOKEN in argv:
        p = os.path.join(run, "manifests", f"{item['id']}.yaml")
        _write_text(p, item.get("manifest") or "")
        argv[argv.index(MANIFEST_TOKEN)] = f"--filename={p}"
    if PATCH_TOKEN in argv:
        ext = "json" if (item.get("patch") or "").lstrip().startswith(("{", "[")) else "yaml"
        p = os.path.join(run, "patches", f"{item['id']}.{ext}")
        _write_text(p, item.get("patch") or "")
        argv[argv.index(PATCH_TOKEN)] = f"--patch-file={p}"
    return argv


def _write_text(p, text):
    os.makedirs(os.path.dirname(p), 0o700, exist_ok=True)
    with open(p, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(p, 0o600)


def _json(r):
    try:
        return json.loads(r.stdout or "null")
    except json.JSONDecodeError:
        return None


def flags_of(argv):
    return {a.split("=", 1)[0]: (a.split("=", 1)[1] if "=" in a else True) for a in argv if a.startswith("--")}


def ensure_context(s, ctx, project, done):
    m = CTX_RE.match(ctx or "")
    if not m:
        raise gglib.Blocked(f"context 要是 gke_<專案>_<位置>_<叢集>:{ctx}")
    if m.group(1) != project:
        raise gglib.Blocked(f"context 的專案 {m.group(1)} 和計畫專案 {project} 不同")
    if ctx not in done:
        r, _ = s.get_credentials(m.group(3), m.group(2))
        if r.returncode != 0:
            raise gglib.Blocked(f"取得叢集憑證失敗 {ctx}:" + gglib._short(r.stderr))
        done.add(ctx)
    return s.context_endpoint(ctx)


def snapshot(s, kind, argv, project, ctx_done):
    """回傳 (snapshot dict, endpoint 或 None, 錯誤字串 或 None)。"""
    k = ggchange.change_rules()["kinds"][kind]
    f = flags_of(argv)
    P = f"--project={project}"
    typ = k["snapshot"]
    endpoint = None

    def g(args):
        r = s.gcloud(args + [P, "--format=json", "--quiet"], mode="dryrun")
        return (_json(r), None) if r.returncode == 0 else (None, gglib._short(r.stderr))

    pos = [a for a in argv if not a.startswith("-")]
    if argv[0] == "gcloud":
        name = pos[len(k["prefix"])] if len(pos) > len(k["prefix"]) else None
        if typ == "cluster":
            snap, err = g(["container", "clusters", "describe", name, f"--location={f.get('--location')}"])
        elif typ == "nodepool":
            snap, err = g(["container", "node-pools", "describe", name, f"--cluster={f.get('--cluster')}",
                           f"--location={f.get('--location')}"])
        elif typ == "resize":
            snap, err = g(["container", "node-pools", "describe", f.get("--node-pool"), f"--cluster={name}",
                           f"--location={f.get('--location')}"])
            if snap is not None:
                ctx = f"gke_{project}_{f.get('--location')}_{name}"
                endpoint = ensure_context(s, ctx, project, ctx_done)
                r = s.kubectl(ctx, ["get", "nodes", "-l", f"cloud.google.com/gke-nodepool={f.get('--node-pool')}",
                                    "-o", "json", "--request-timeout=60s"], mode="dryrun")
                nodes = (_json(r) or {}).get("items") if r.returncode == 0 else None
                zones = len(snap.get("locations") or []) or 1
                if nodes is None:
                    err = "讀不到節點數:" + gglib._short(r.stderr)
                else:
                    snap = {"nodepool": snap, "node_count": len(nodes), "zones": zones,
                            "node_count_per_zone": len(nodes) // zones if len(nodes) % zones == 0 else None}
        elif typ == "firewall":
            snap, err = g(["compute", "firewall-rules", "describe", name])
        elif typ == "bucket":
            snap, err = g(["storage", "buckets", "describe", name])
        elif typ == "bucket-iam":
            snap, err = g(["storage", "buckets", "get-iam-policy", name])
        elif typ == "project-iam":
            snap, err = g(["projects", "get-iam-policy", project])
        elif typ == "sql":
            snap, err = g(["sql", "instances", "describe", name])
        else:
            return None, None, f"未知快照類型 {typ}"
        return snap, endpoint, err
    # kubectl
    ctx = argv[1][len("--context="):]
    endpoint = ensure_context(s, ctx, project, ctx_done)
    ns = f.get("--namespace")
    rest = [a for a in argv[2 + len(k["prefix"]) - 1:] if not a.startswith("--")]

    def kget(kind_, name_, ns_):
        args = ["get", kind_, name_] + (["-n", ns_] if ns_ else []) + ["-o", "json", "--request-timeout=60s"]
        r = s.kubectl(ctx, args, mode="dryrun")
        if r.returncode != 0:
            if "NotFound" in r.stderr or "not found" in r.stderr:
                return {"_absent": True}, None
            return None, gglib._short(r.stderr)
        return _json(r), None

    if typ == "k8s-object":
        if kind == "kubectl-patch":
            kind_, name_ = rest[0], rest[1]
        else:
            kind_, name_ = rest[0].split("/", 1)
        snap, err = kget(kind_, name_, ns)
        return snap, endpoint, err
    if typ == "k8s-namespace":
        snap, err = kget("namespace", rest[0], None)
        return snap, endpoint, err
    if typ == "k8s-manifest":
        path = f["--filename"]
        objs = []
        for d in yaml_docs(path):
            o = d["obj"]
            md = o.get("metadata") or {}
            if not o.get("kind") or not md.get("name"):
                return None, endpoint, "manifest 每份文件都要有 kind 與 metadata.name"
            rules_ = ggchange.change_rules()
            if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", str(o["kind"])) or o["kind"].lower() in rules_["k8s_forbidden_kinds"] \
                    or o["kind"].lower() not in rules_["k8s_patch_kinds"]:
                return None, endpoint, f"manifest 不允許這種資源:{o['kind']}"
            snap1, err = kget(o["kind"].lower(), md["name"], md.get("namespace"))
            if err:
                return None, endpoint, err
            objs.append(snap1)
        return {"objects": objs}, endpoint, None
    return None, endpoint, f"未知快照類型 {typ}"


def yaml_docs(path):
    r = subprocess.run(["ruby", os.path.join(gglib.KIT, "scripts", "yaml2json.rb"), path],
                       capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        raise gglib.Blocked("manifest / patch 不是有效 YAML:" + gglib._short(r.stderr))
    return json.loads(r.stdout or "[]")


SKIP_DRYRUN_RULES = {"K8S-NP-001", "K8S-PSA-001"}


def _obj_findings(objs):
    docs = [{"obj": o, "file": "dry-run"} for o in objs if isinstance(o, dict) and not o.get("_absent")]
    return [f for f in k8s_rules.scan(docs, live=False) if f["rule_id"] not in SKIP_DRYRUN_RULES]


def k8s_dryrun(s, kind, argv, snap):
    """回傳 (created: bool|None, 新增的 findings, 紀錄文字, 錯誤)。"""
    ctx = argv[1][len("--context="):]
    f = flags_of(argv)
    log = []
    if kind == "kubectl-apply":
        path = f["--filename"]
        r = s.kubectl(ctx, ["diff", "-f", path, "--request-timeout=60s"], mode="dryrun")
        log.append(("kubectl diff", r.returncode, diff_summary(r.stdout)))
        if r.returncode > 1:
            return None, [], log, "kubectl diff 失敗:" + gglib._short(r.stderr)
        created = bool(re.search(r"^@@ -0,0 ", r.stdout, re.M)) or \
            any(o.get("_absent") for o in (snap or {}).get("objects") or [])
        r = s.kubectl(ctx, ["apply", "--dry-run=server", "-o", "json", "-f", path, "--request-timeout=60s"], mode="dryrun")
        log.append(("kubectl apply --dry-run=server", r.returncode, ""))
        if r.returncode != 0:
            return created, [], log, "server dry-run 失敗:" + gglib._short(r.stderr)
        out = _json(r) or {}
        after = out.get("items") if out.get("kind") == "List" else [out]
        before = (snap or {}).get("objects") or []
    else:  # patch
        rest = [a for a in argv[3:] if not a.startswith("--")]
        args = ["patch", rest[0], rest[1]] + (["-n", f["--namespace"]] if f.get("--namespace") else []) + \
            [f"--type={f['--type']}", f"--patch-file={f['--patch-file']}", "--dry-run=server", "-o", "json",
             "--request-timeout=60s"]
        r = s.kubectl(ctx, args, mode="dryrun")
        log.append(("kubectl patch --dry-run=server", r.returncode, ""))
        if r.returncode != 0:
            return False, [], log, "server dry-run 失敗:" + gglib._short(r.stderr)
        after, before, created = [_json(r) or {}], [snap or {}], False
    key = lambda x: (x["rule_id"], x["resource"], x["evidence"].get("path"))
    old = {key(x) for x in _obj_findings(before)}
    new = [x for x in _obj_findings(after) if key(x) not in old]
    return created, new, log, None


def diff_summary(out):
    """只保留「哪些資源有差異、是否新建」,不保留 diff 內容(可能含 env / ConfigMap 原值)。"""
    res, cur = [], None
    for line in out.splitlines():
        m = re.match(r"^diff -u -N \S+/([^/\s]+) ", line)
        if m:
            cur = {"resource": m.group(1), "created": False}
            res.append(cur)
        elif cur and line.startswith("@@ -0,0 "):
            cur["created"] = True
    return "\n".join(f"{x['resource']}\t{'新建' if x['created'] else '修改'}" for x in res) or "（無差異)"


def check_pre(pre_list, snap):
    """回傳不成立的條件清單。"""
    bad = []
    for p in pre_list or []:
        if "field" in p:
            cur = gglib.ptr_get(snap, p["field"])
            if cur != p.get("expect"):
                bad.append({"cond": p, "actual": cur})
        elif "binding_absent" in p:
            if ggchange._has_binding(snap, *p["binding_absent"]):
                bad.append({"cond": p, "actual": "綁定已存在"})
        elif "binding_present" in p:
            if not ggchange._has_binding(snap, *p["binding_present"]):
                bad.append({"cond": p, "actual": "綁定不存在"})
        else:
            bad.append({"cond": p, "actual": "看不懂的條件"})
    return bad


def stable_dump(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
