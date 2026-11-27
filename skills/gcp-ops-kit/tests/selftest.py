"""gcp-ops-kit selftest:只用假 gcloud / kubectl(tests/stub),不連任何雲端。

python3 tests/selftest.py [-v]
每個案例印 PASS / FAIL;有 FAIL 結束碼 1。暫存目錄結束時刪除。
"""
import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
KIT = os.path.dirname(HERE)
S = os.path.join(KIT, "scripts")
sys.path.insert(0, S)
sys.path.insert(0, HERE)
import fixtures as FX  # noqa: E402
import gglib  # noqa: E402
import ggchange  # noqa: E402
import gcp_rules  # noqa: E402
import k8s_rules  # noqa: E402

VERBOSE = "-v" in sys.argv
RESULTS = []


def ok(name, cond, detail=""):
    RESULTS.append((name, bool(cond)))
    print(("PASS " if cond else "FAIL ") + name + ("" if cond or not detail else f"\n     {detail}"))


class Env:
    def __init__(self):
        self.tmp = tempfile.mkdtemp(prefix="gg-selftest-")
        self.reports = os.path.join(self.tmp, "reports")
        self.stub = os.path.join(self.tmp, "stubdir")
        os.makedirs(self.stub)
        conf = os.path.join(self.tmp, "conf")
        os.makedirs(conf, 0o700)
        self.key = os.path.join(conf, "sa.json")
        with open(self.key, "w") as f:
            json.dump({"type": "service_account", "client_email": FX.GG_SA, "private_key_id": "x"}, f)
        os.chmod(self.key, 0o600)
        self.cfg = os.path.join(conf, "config")
        with open(self.cfg, "w") as f:
            f.write(f"GG_SA_KEY_FILE={self.key}\nGG_REPORT_DIR={self.reports}\n")
        os.chmod(self.cfg, 0o600)
        self.log = os.path.join(self.tmp, "stub.log")
        self.set_fixtures(FX.review_fixtures())
        self.state({})

    def set_fixtures(self, fx):
        with open(os.path.join(self.stub, "fixtures.json"), "w") as f:
            json.dump(fx, f)

    def state(self, st):
        with open(os.path.join(self.stub, "state.json"), "w") as f:
            json.dump(st, f)

    def env(self, stub=True):
        e = {"PATH": (os.path.join(HERE, "stub") + ":" if stub else "") + "/usr/bin:/bin:/usr/sbin:/opt/homebrew/bin:/usr/local/bin",
             "HOME": os.environ.get("HOME", ""), "GG_CONFIG": self.cfg, "GG_STUB_DIR": self.stub,
             "GG_STUB_LOG": self.log, "TMPDIR": self.tmp}
        return e

    def run(self, args, stub=True, env=None):
        r = subprocess.run(args, env=env or self.env(stub), capture_output=True, text=True, timeout=300)
        if VERBOSE:
            print("  $", " ".join(args), "\n ", r.stdout[-2000:], r.stderr[-2000:])
        return r

    def stub_calls(self):
        if not os.path.exists(self.log):
            return []
        return [json.loads(l) for l in open(self.log)]

    def clear_log(self):
        if os.path.exists(self.log):
            os.remove(self.log)

    def close(self):
        if os.environ.get("GG_SELFTEST_KEEP"):
            print(f"保留暫存目錄:{self.tmp}")
            return
        shutil.rmtree(self.tmp, ignore_errors=True)


def run_dir(out):
    for line in out.splitlines():
        if line.startswith("run="):
            return line[4:]
    return None


# ------------------------------------------------------------------ 單元測試

def t_allowlists():
    P, CTX = FX.P, f"gke_{FX.P}_asia-east1_prod"
    allow = [
        ["gcloud", "projects", "get-iam-policy", P, f"--project={P}", "--format=json", "--quiet"],
        ["gcloud", "auth", "activate-service-account", "<key>", f"--project={P}", "--quiet"],
        ["kubectl", f"--context={CTX}", "get", "pods", "-A", "-o", "json", "--request-timeout=60s"],
        ["kubectl", f"--context={CTX}", "get", "secrets", "-A", "-o=go-template=" + gglib.SECRET_TMPL, "--request-timeout=60s"],
    ]
    deny = [
        ["kubectl", f"--context={CTX}", "get", "secret", "db", "-n", "shop", "-o", "yaml"],
        ["kubectl", f"--context={CTX}", "get", "secrets", "-A", "-o", "json", "--request-timeout=60s"],
        ["gcloud", "compute", "instances", "get-serial-port-output", "vm1", f"--project={P}", "--format=json", "--quiet"],
        ["kubectl", f"--context={CTX}", "get", "--raw", "/api/v1/secrets"],
        ["gcloud", "secrets", "versions", "access", "latest", "--secret=x", f"--project={P}"],
        ["kubectl", f"--context={CTX}", "exec", "web", "--", "sh"],
        ["gcloud", "compute", "instances", "delete", "vm1", f"--project={P}", "--format=json", "--quiet"],
        ["gcloud", "auth", "print-access-token", f"--project={P}"],
        ["kubectl", f"--context={CTX}", "get", "Secret", "db", "-n", "shop", "-o", "json", "--request-timeout=60s"],
        ["kubectl", f"--context={CTX}", "get", "secrets.v1", "db", "-n", "shop", "-o", "json", "--request-timeout=60s"],
        ["kubectl", f"--context={CTX}", "get", "secret/db", "-n", "shop", "-o", "json", "--request-timeout=60s"],
        ["kubectl", f"--context={CTX}", "patch", "Secret", "db", "-n", "shop", "--type=merge", "--patch-file=/r/patches/C1.json", "--dry-run=server", "-o", "json", "--request-timeout=60s"],
    ]
    allow_dry = [["kubectl", f"--context={CTX}", "patch", "deployment", "app-secret", "-n", "shop", "--type=merge",
                  "--patch-file=/r/my-secret/patches/C1.json", "--dry-run=server", "-o", "json", "--request-timeout=60s"]]
    for a in allow_dry:
        try:
            gglib.check_read(a, "dryrun")
            ok("dry-run 允許:名稱 / 路徑含 secret 字樣的 deployment patch", True)
        except gglib.Denied as ex:
            ok("dry-run 允許:名稱 / 路徑含 secret 字樣的 deployment patch", False, str(ex))
    for a in allow:
        try:
            gglib.check_read(a, "read")
            ok("白名單允許:" + " ".join(a[:4]), True)
        except gglib.Denied as e:
            ok("白名單允許:" + " ".join(a[:4]), False, str(e))
    for a in deny:
        try:
            gglib.check_read(a, "dryrun")
            ok("白名單拒絕:" + " ".join(a[:6]), False, "沒被拒絕")
        except gglib.Denied:
            ok("白名單拒絕:" + " ".join(a[:6]), True)


def t_guard(e):
    g = os.path.join(S, "guard.py")
    k = S
    cases = [
        (f"{k}/collect.sh {FX.P}", "allow"),
        (f"bash {k}/check.sh yaml", "allow"),
        (f"python3 {k}/plan.py build /x/run", "allow"),
        (f'{k}/change.sh /x/plan.json --sha abc --approved "使用者已核准變更 C1, C3"', "allow"),
        ("ls -la /tmp", "allow"),
        ("gcloud projects list", "deny"),
        ("kubectl get pods", "deny"),
        (f"{k}/check.sh yaml; gcloud compute instances delete vm1", "deny"),
        (f"{k}/check.sh yaml && kubectl delete ns shop", "deny"),
        (f"{k}/check.sh yaml | sh", "deny"),
        (f"{k}/check.sh $(gcloud auth print-access-token)", "deny"),
        (f"{k}/check.sh yaml\ngcloud projects list", "deny"),
        (f"python3 {k}/gglib.py", "deny"),
        (f"python3 -c 'import os'", "deny"),
        (f"cat {e.key}", "deny"),
        (f"cat {e.cfg}", "deny"),
        ("curl https://example.com", "deny"),
        ("env CLOUDSDK_CONFIG=/tmp/x gcloud projects list", "deny"),
        ("bash -c 'echo hi'", "deny"),
        (f"find {e.tmp} -exec rm {{}} +", "deny"),
        (f"grep -r private_key {e.tmp}", "deny"),
        (f"grep -r private_key {os.path.dirname(e.tmp)}", "deny"),
        (f"grep --file={e.key} x {e.reports}", "deny"),
        (f"grep -f{e.key} x", "deny"),
        (f"cat {e.reports}/p/r/report.html", "allow"),
        (f"ls {e.tmp}", "allow"),
        (f"ls -laR {e.reports}", "deny-live"),
        (f"file {e.reports}", "deny"),
        ("jq -n env", "deny"),
        (f"node {S}/render.mjs --check {e.reports}/p/20261127-000001-change", "allow"),
        (f"cat {e.cfg.replace('/conf/', '/CONF/')}", "deny"),
        (f"cat {e.key.replace('sa.json', 'SA.JSON')}", "deny"),
        (f"grep -r private_key {e.reports}", "deny-live"),
        (f"cat {e.reports}/p/20261127-000000-change/before/C1.rollback.json", "deny"),
    ]
    env = e.env()
    live = os.path.join(e.reports, "p", "20261127-000000-review", "gcloud")
    os.makedirs(live)
    rb = os.path.join(e.reports, "p", "20261127-000001-change", "before")
    os.makedirs(rb)
    open(os.path.join(rb, "C1.rollback.json"), "w").write("{}")
    for cmd, want in cases:
        want = "deny" if want == "deny-live" else want
        r = subprocess.run(["python3", g, "--test", cmd], env=env, capture_output=True, text=True)
        got = r.stdout.split("\t")[0].strip()
        ok(f"guard {want}:{cmd[:70]!r}", got == want, r.stdout + r.stderr)
    # 實際 hook 介面(stdin JSON)
    for tool, inp, want in (("Write", {"file_path": os.path.join(e.reports, "x", "report.html")}, 2),
                            ("Read", {"file_path": e.key}, 2),
                            ("Read", {"file_path": os.path.join(e.tmp, "conf", "other.txt")}, 2),
                            ("Read", {"file_path": os.path.join(e.reports, "p", "r", "report.html")}, 0),
                            ("Write", {"file_path": os.path.join(e.reports, "p", "r", "plan.json")}, 2),
                            ("Grep", {"pattern": "private_key", "path": e.tmp}, 2),
                            ("Glob", {"pattern": e.tmp + "/**/*.json"}, 2),
                            ("Grep", {"pattern": "x", "path": e.reports}, 2),
                            ("Grep", {"pattern": "x", "path": os.path.join(e.reports, "p", "other-run")}, 0)):
        r = subprocess.run(["python3", g], input=json.dumps({"tool_name": tool, "tool_input": inp, "cwd": "/"}),
                           env=env, capture_output=True, text=True)
        tgt = inp.get("file_path") or inp.get("path") or inp.get("pattern")
        ok(f"guard hook {tool} {os.path.relpath(tgt, e.tmp) if tgt.startswith('/') else tgt} → {want}", r.returncode == want, r.stderr)
    os.makedirs(os.path.join(e.tmp, "sub"), exist_ok=True)
    for cwd, cmd, want in ((os.path.join(e.tmp, "sub"), "grep -o -f../conf/sa.json . /tmp/dict", 2),
                           (os.path.dirname(e.tmp), "grep -r private_key", 2), (os.path.dirname(e.tmp), "grep -rl x", 2),
                           (os.path.dirname(e.tmp), "find -name sa.json", 2), (os.path.join(e.reports, "p", "other"), "grep -n x", 0)):
        r = subprocess.run(["python3", g], input=json.dumps({"tool_name": "Bash", "tool_input": {"command": cmd}, "cwd": cwd}),
                           env=env, capture_output=True, text=True)
        ok(f"guard cwd 隱含路徑:{cmd!r} → {want}", r.returncode == want, r.stderr)
    shutil.rmtree(os.path.dirname(live))


def t_redact():
    cm = {"kind": "ConfigMap", "data": {"k": FX.FAKE_AIZA}}
    sec = {"kind": "Secret", "data": {"p": "c2VjcmV0"}, "stringData": {"q": "plain"}}
    vm = {"metadata": {"items": [{"key": "serial-port-enable", "value": "TRUE"}, {"key": "startup-script", "value": "x=1"}]}}
    pod = {"spec": {"containers": [{"env": [{"name": "DB_PASSWORD", "value": "hunter2-very-secret"}, {"name": "LOG", "value": "info"}]}]}}
    r = gglib.redact({"items": [cm, sec, vm, pod, {"masterAuth": {"clientKey": "abc", "password": ""}}]})
    s = json.dumps(r)
    ok("遮蔽:ConfigMap / Secret / env / masterAuth 值不留原文",
       all(x not in s for x in (FX.FAKE_AIZA, "c2VjcmV0", "plain", "hunter2", "x=1", '"abc"')), s)
    ok("遮蔽:metadata 布林設定保留明文", '"value": "TRUE"' in s)
    a = gglib.redact({"spec": {"containers": [{"args": ["--db-password=hunter2xyz", "--token", "abc123token", "--port=80"]}]},
                      "config": {"metadata": {"disable-legacy-endpoints": "true", "startup": "secret=1"}}})
    sa = json.dumps(a)
    ok("遮蔽:容器 args 的密碼 / token 值、node pool config.metadata 值",
       "hunter2xyz" not in sa and "abc123token" not in sa and "--port=80" in sa and '"disable-legacy-endpoints": "true"' in sa and "secret=1" not in sa, sa)
    env = r["items"][3]["spec"]["containers"][0]["env"]
    ok("遮蔽:env 標 looks_secret", env[0]["looks_secret"] is True and env[1]["looks_secret"] is False, env)


def t_misc():
    ok("ptr_get 拒絕負數索引", gglib.ptr_get({"a": [1, 2]}, "/a/-1", "NONE") == "NONE" and gglib.ptr_get({"a": [1, 2]}, "/a/1") == 2)


def t_yaml_bool():
    r = subprocess.run(["ruby", os.path.join(S, "yaml2json.rb"), "-"], input="a: yes\nb: on\nc: \"yes\"\nd: off\ne: n\n",
                       capture_output=True, text=True)
    obj = json.loads(r.stdout)[0]["obj"]
    ok("YAML 1.1 布林:yes / on → true、off / n → false、引號字串不變", obj == {"a": True, "b": True, "c": "yes", "d": False, "e": False}, obj)


def t_approve_parse():
    import change
    good = {"使用者已核准變更 C1, C3": ["C1", "C3"], "使用者已核准變更C1、C3": ["C1", "C3"], "使用者已核准變更 C2": ["C2"],
            "使用者已核准變更 C1\uff0cC3": ["C1", "C3"]}
    for t, want in good.items():
        try:
            ok(f"核准旗標解析:{t}", change.parse_approved(t) == want, change.parse_approved(t))
        except gglib.Blocked as ex:
            ok(f"核准旗標解析:{t}", False, str(ex))
    for t in ("使用者已核准變更 C1、C3,C2 先不要", "請做 C1", "使用者已核准變更 全部", "使用者已核准變更 C1 和 C2"):
        try:
            change.parse_approved(t)
            ok(f"核准旗標拒絕:{t}", False)
        except gglib.Blocked:
            ok(f"核准旗標拒絕:{t}", True)


def t_rule_tables():
    levels = {"嚴重", "高", "中", "低", "資訊"}
    ok("每條 GCP 規則有固定嚴重度", all(v[0] in levels for v in gcp_rules.RULES.values()))
    ok("每條 k8s 規則有固定嚴重度", all(v[0] in levels for v in k8s_rules.RULES.values()))


def t_classify():
    cfg = {"GG_SA": FX.GG_SA}
    P, CTX = FX.P, f"gke_{FX.P}_asia-east1_prod"
    fw = FX.FIREWALLS[0]
    iap = FX.FIREWALLS[3]
    pol = FX.POLICY
    np_snap = {"nodepool": FX.NODEPOOLS[0], "node_count": 4, "zones": 2, "node_count_per_zone": 2}
    blocked = [
        ("delete", ["gcloud", "compute", "instances", "delete", "vm1", f"--project={P}"], {}),
        ("set-iam-policy", ["gcloud", "projects", "set-iam-policy", P, "p.json", f"--project={P}"], {}),
        ("services disable", ["gcloud", "services", "disable", "container.googleapis.com", f"--project={P}"], {}),
        ("--release-channel", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--release-channel=rapid"], FX.CLUSTER),
        ("--cluster-version", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--cluster-version=1.34"], FX.CLUSTER),
        ("resize 到 0", ["gcloud", "container", "clusters", "resize", "prod", "--node-pool=default-pool", "--num-nodes=0", "--location=asia-east1", f"--project={P}"], np_snap),
        ("停用 IAP 防火牆", ["gcloud", "compute", "firewall-rules", "update", "allow-iap", f"--project={P}", "--disabled"], iap),
        ("新增 owner", ["gcloud", "projects", "add-iam-policy-binding", P, "--member=user:x@example.com", "--role=roles/owner", f"--project={P}"], pol),
        ("移除 owner", ["gcloud", "projects", "remove-iam-policy-binding", P, "--member=user:alice@example.com", "--role=roles/owner", f"--project={P}"], pol),
        ("動 GG_SA 自己", ["gcloud", "projects", "remove-iam-policy-binding", P, f"--member=serviceAccount:{FX.GG_SA}", "--role=roles/editor", f"--project={P}"], pol),
        ("新增 allUsers", ["gcloud", "storage", "buckets", "add-iam-policy-binding", "gs://b", "--member=allUsers", "--role=roles/storage.objectViewer", f"--project={P}"], {}),
        ("來源 0.0.0.0/0", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--source-ranges=0.0.0.0/0"], fw),
        ("--rules=all", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--rules=all"], fw),
        ("--rules=tcp:1-65535", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--rules=tcp:1-65535"], fw),
        ("gcloud 缺 --project", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", "--source-ranges=10.0.0.0/8"], fw),
        ("kubectl 缺 --context", ["kubectl", "scale", "deployment/web", "--namespace=shop", "--replicas=3"], FX.DEPLOY),
        ("不可還原(security-posture)", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--security-posture=enterprise"], FX.CLUSTER),
        ("kubectl delete", ["kubectl", f"--context={CTX}", "delete", "namespace", "shop"], {}),
        ("apply --prune", ["kubectl", f"--context={CTX}", "apply", "--filename=/x/manifests/C1.yaml", "--prune"], {}),
        ("0::/0 寫法", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--master-authorized-networks=0::/0"], FX.CLUSTER),
        ("0.0.0.0/1 + 128.0.0.0/1", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--source-ranges=0.0.0.0/1,128.0.0.0/1"], fw),
        ("已是目標狀態的反向旗標(shielded nodes 已開)", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--enable-shielded-nodes"], FX.CLUSTER),
        ("帶 condition 的 IAM 新增", ["gcloud", "projects", "add-iam-policy-binding", P, "--member=user:x@example.com", "--role=roles/viewer", f"--project={P}", "--condition=expression=true,title=t"], pol),
        ("patch 大寫 Secret(快照前就擋)", ["kubectl", f"--context={CTX}", "patch", "Secret", "db", "--namespace=shop", "--type=merge", "--patch-file=/x/patches/C1.json"], None),
        ("patch namespace", ["kubectl", f"--context={CTX}", "patch", "namespace", "prod", "--type=merge", "--patch-file=/x/patches/C1.json"], None),
        ("--logging 沒有可靠還原", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--logging=SYSTEM,WORKLOAD"], FX.CLUSTER),
        ("deny 防火牆規則", ["gcloud", "compute", "firewall-rules", "update", "deny-ssh", f"--project={P}", "--rules=tcp:23"],
         {"name": "deny-ssh", "direction": "INGRESS", "denied": [{"IPProtocol": "tcp", "ports": ["22"]}], "sourceRanges": ["10.0.0.0/8"]}),
        ("授權網路已啟用且清單空(還原會變寬)", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}",
                                          "--master-authorized-networks=10.0.0.0/8"], dict(FX.CLUSTER, masterAuthorizedNetworksConfig={"enabled": True})),
        ("授權網路只給網段沒帶 enable", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}",
                                       "--master-authorized-networks=10.1.0.0/16"], dict(FX.CLUSTER, masterAuthorizedNetworksConfig={"enabled": True, "cidrBlocks": [{"cidrBlock": "10.0.0.0/8"}]})),
        ("deployment 縮到 0", ["kubectl", f"--context={CTX}", "scale", "deployment/web", "--namespace=shop", "--replicas=0"], FX.DEPLOY),
        ("member 大寫", ["gcloud", "projects", "add-iam-policy-binding", P, "--member=user:Alice@example.com", "--role=roles/viewer", f"--project={P}"], pol),
        ("bucket 狀態欄位不存在", ["gcloud", "storage", "buckets", "update", "gs://b", f"--project={P}", "--versioning"], {}),
    ]
    for name, argv, snap in blocked:
        r = ggchange.classify(argv, cfg, snap, shape_only=snap is None)
        ok(f"分類 BLOCKED:{name}", r["blocked_reason"], r)
    r = ggchange.classify(["kubectl", f"--context={CTX}", "apply", "--filename=/x/manifests/C1.yaml"], cfg,
                          {"objects": [{"_absent": True}]}, [], True)
    ok("分類:apply 新建資源 → 不可還原 BLOCKED", r["blocked_reason"] and r["reversible"] is False, r)
    r = ggchange.classify(["kubectl", f"--context={CTX}", "apply", "--filename=/x/manifests/C1.yaml"], cfg,
                          {"objects": [FX.DEPLOY]}, [{"severity": "高", "rule_id": "K8S-PRIV-001", "title": "privileged"}], False)
    ok("分類:apply 套用後產生高風險(privileged)→ BLOCKED", r["blocked_reason"] and "K8S-PRIV-001" in r["blocked_reason"], r)
    okcases = [
        ("移除 bucket allUsers", ["gcloud", "storage", "buckets", "remove-iam-policy-binding", "gs://public-assets", "--member=allUsers",
                                 "--role=roles/storage.objectViewer", f"--project={P}"],
         {"bindings": [{"role": "roles/storage.objectViewer", "members": ["allUsers"]}]}, False),
        ("收緊防火牆來源", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--source-ranges=35.235.240.0/20"], fw, True),
        ("node pool 2→3", ["gcloud", "container", "clusters", "resize", "prod", "--node-pool=default-pool", "--num-nodes=3",
                          "--location=asia-east1", f"--project={P}"], np_snap, False),
        ("新增高權角色(放寬)", ["gcloud", "projects", "add-iam-policy-binding", P, "--member=user:x@example.com", "--role=roles/editor", f"--project={P}"], pol, True),
        ("開 shielded nodes(原本關)", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--enable-shielded-nodes"],
         dict(FX.CLUSTER, shieldedNodes={}), False),
        ("開控制平面授權網路(原本關、清單空)", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}",
                                        "--enable-master-authorized-networks", "--master-authorized-networks=203.0.113.0/24"], FX.CLUSTER, False),
        ("防火牆 tcp:443,icmp(icmp 不算全開)", ["gcloud", "compute", "firewall-rules", "update", "allow-web", f"--project={P}", "--rules=tcp:8080,icmp"],
         dict(FX.FIREWALLS[1], allowed=[{"IPProtocol": "tcp", "ports": ["8080"]}, {"IPProtocol": "icmp"}]), False),
        ("收窄已啟用的授權網路", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}",
                              "--enable-master-authorized-networks", "--master-authorized-networks=10.1.0.0/16"],
         dict(FX.CLUSTER, masterAuthorizedNetworksConfig={"enabled": True, "cidrBlocks": [{"cidrBlock": "10.0.0.0/8"}]}), False),
        ("Cloud SQL 原本沒有授權網路", ["gcloud", "sql", "instances", "patch", "db1", f"--project={P}", "--authorized-networks=203.0.113.0/24"],
         {"settings": {"ipConfiguration": {"ipv4Enabled": True}}}, True),
        ("新增 IAM(還原帶 --condition=None)", ["gcloud", "projects", "add-iam-policy-binding", P, "--member=user:x@example.com", "--role=roles/viewer", f"--project={P}"], pol, False),
        ("清空防火牆 target-tags(放寬)", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--target-tags="],
         dict(fw, targetTags=["bastion"]), True),
        ("提高防火牆優先序(放寬)", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--priority=100"], fw, True),
        ("SQL 取消用戶端憑證(放寬)", ["gcloud", "sql", "instances", "patch", "db1", f"--project={P}", "--ssl-mode=ENCRYPTED_ONLY"],
         {"settings": {"ipConfiguration": {"sslMode": "TRUSTED_CLIENT_CERTIFICATE_REQUIRED"}}}, True),
        ("移除 SA 的 editor(serviceAccount: 前綴)", ["gcloud", "projects", "remove-iam-policy-binding", P, f"--member=serviceAccount:{FX.DEF_SA}",
                                               "--role=roles/editor", f"--project={P}"], pol, False),
        ("防火牆從全部 VM 收窄到 tag", ["gcloud", "compute", "firewall-rules", "update", "allow-ssh", f"--project={P}", "--target-tags=bastion"], fw, False),
        ("關閉授權網路(還原帶回原網段)", ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}",
                                       "--no-enable-master-authorized-networks"],
         dict(FX.CLUSTER, masterAuthorizedNetworksConfig={"enabled": True, "cidrBlocks": [{"cidrBlock": "10.0.0.0/8"}]}), True),
        ("關閉 autoscaling(還原帶回 min / max)", ["gcloud", "container", "node-pools", "update", "default-pool", "--cluster=prod", "--location=asia-east1",
                                            f"--project={P}", "--no-enable-autoscaling"],
         {"autoscaling": {"enabled": True, "minNodeCount": 1, "maxNodeCount": 5}}, False),
        ("開 bucket 版本(原本關)", ["gcloud", "storage", "buckets", "update", "gs://b", f"--project={P}", "--versioning"], {"versioning_enabled": False}, False),
    ]
    for name, argv, snap, loosens in okcases:
        r = ggchange.classify(argv, cfg, snap)
        good = not r["blocked_reason"] and r["reversible"] and r["rollback"]
        if name == "開 shielded nodes(原本關)":
            good = good and {"field": "/shieldedNodes/enabled", "expect": None} in r["auto_pre"]
        if name.startswith("關閉授權網路"):
            good = good and "--master-authorized-networks=10.0.0.0/8" in r["rollback"]
        if name.startswith("關閉 autoscaling"):
            good = good and "--min-nodes=1" in r["rollback"] and "--max-nodes=5" in r["rollback"]
        if name == "收窄已啟用的授權網路":
            good = good and "--enable-master-authorized-networks" in r["rollback"] and "--master-authorized-networks=10.0.0.0/8" in r["rollback"] \
                and "--no-enable-master-authorized-networks" not in r["rollback"]
        if name == "Cloud SQL 原本沒有授權網路":
            good = not r["blocked_reason"] and r["reversible"] and "--clear-authorized-networks" in r["rollback"]
        if name.startswith("新增 IAM"):
            good = good and "--condition=None" in r["rollback"]
        if name.startswith("開控制平面授權網路"):
            good = good and r["rollback"].count("--no-enable-master-authorized-networks") == 1
        if name == "收緊防火牆來源":
            good = good and not r["loosens_security"] and "--source-ranges=0.0.0.0/0" in r["rollback"]
        else:
            good = good and r["loosens_security"] == loosens
        ok(f"分類可執行:{name}", good, r)


def t_yaml(e):
    bad = os.path.join(HERE, "testdata", "yaml", "bad")
    good = os.path.join(HERE, "testdata", "yaml", "good")
    env = e.env(stub=False)
    env["GG_CONFIG"] = os.path.join(e.tmp, "no-such-config")
    env["GG_REPORT_DIR"] = e.reports
    # 沒有設定檔時報告放預設目錄;為了不寫到家目錄,用暫存設定只給 GG_REPORT_DIR
    cfg2 = os.path.join(e.tmp, "config-yaml-only")
    with open(cfg2, "w") as f:
        f.write(f"GG_REPORT_DIR={e.reports}\n")
    env["GG_CONFIG"] = cfg2
    has_gcloud = shutil.which("gcloud", path=env["PATH"]) is not None
    r = e.run([os.path.join(S, "yaml-review.sh"), bad, "--label", "bad"], env=env)
    run = run_dir(r.stdout)
    fs = json.load(open(os.path.join(run, "findings.json"))) if run else []
    want = sorted(["K8S-HOST-001", "K8S-HOST-002", "K8S-SA-001", "K8S-PRIV-001", "K8S-CAP-001", "K8S-ROOT-001", "K8S-ROFS-001",
                   "K8S-IMG-001", "K8S-RES-001", "K8S-PROBE-001", "K8S-SEC-002", "K8S-SEC-001", "K8S-LB-001",
                   "K8S-RBAC-001", "K8S-RBAC-002", "K8S-NP-001", "K8S-PSA-001"])
    got = sorted(f["rule_id"] for f in fs)
    ok(f"YAML 審查(無 gcloud={not has_gcloud}、無金鑰):問題樣本完全命中", r.returncode == 0 and got == want, f"rc={r.returncode} got={got}\n{r.stderr}")
    ok("YAML 審查:每條有 檔:行", all(f["evidence"].get("file") and f["evidence"].get("line") for f in fs))
    ok("YAML 審查:秘密值不入 findings", "hunter2" not in json.dumps(fs) and "s3cr3t" not in json.dumps(fs))
    r2 = e.run(["node", os.path.join(S, "render.mjs"), "--check", run], env=env) if run else None
    ok("YAML 審查:render --check 通過", r2 and r2.returncode == 0, r2.stderr if r2 else "")
    kd = os.path.join(e.tmp, "kust")
    os.makedirs(kd)
    shutil.copy(os.path.join(good, "app.yaml"), kd)
    with open(os.path.join(kd, "kustomization.yaml"), "w") as f:
        f.write("resources: [app.yaml]\nsecretGenerator:\n- name: db\n  namespace: shop\n  literals: [DB_PASSWORD=hunter2kustomize]\n")
    lb = os.path.join(e.tmp, "lb")
    os.makedirs(lb)
    with open(os.path.join(lb, "svc.yaml"), "w") as f:
        f.write("apiVersion: v1\nkind: Service\nmetadata:\n  name: ilb\n  namespace: shop\n  annotations:\n    cloud.google.com/load-balancer-type: Internal\nspec:\n  type: LoadBalancer\n")
    r = e.run([os.path.join(S, "yaml-review.sh"), lb, "--label", "lb"], env=env)
    run = run_dir(r.stdout)
    fs = json.load(open(os.path.join(run, "findings.json"))) if run else ["x"]
    ok("YAML 審查:cloud.google.com 內部 LB 不報 K8S-LB-001", not any(f["rule_id"] == "K8S-LB-001" for f in fs), fs)
    kenv = dict(env)
    real_kubectl = shutil.which("kubectl")  # 用真的 kubectl kustomize(不連叢集)
    if real_kubectl:
        kenv["PATH"] = os.path.dirname(real_kubectl) + ":" + env["PATH"]
    else:
        print("SKIP kustomize 測試:本機沒有 kubectl")
    r = e.run([os.path.join(S, "yaml-review.sh"), kd, "--label", "kust"], env=kenv)
    run = run_dir(r.stdout)
    blob = ""
    for root, _, fns in os.walk(run or e.tmp):
        for fn in fns:
            blob += open(os.path.join(root, fn), encoding="utf-8", errors="ignore").read()
    import base64
    r2 = e.run(["node", os.path.join(S, "render.mjs"), "--check", run], env=env) if run else None
    fs = json.load(open(os.path.join(run, "findings.json"))) if run else []
    ok("YAML 審查 kustomize:secretGenerator 的值不落地(明文與 base64 都沒有)、--check ok、有 K8S-SEC-001",
       not real_kubectl or run and "hunter2kustomize" not in blob and base64.b64encode(b"hunter2kustomize").decode() not in blob
       and r2.returncode == 0 and any(f["rule_id"] == "K8S-SEC-001" for f in fs), (r.stderr[-500:], r2.stderr if r2 else ""))
    r = e.run([os.path.join(S, "yaml-review.sh"), good, "--label", "good"], env=env)
    run = run_dir(r.stdout)
    fs = json.load(open(os.path.join(run, "findings.json"))) if run else ["x"]
    ok("YAML 審查:乾淨樣本零誤報", r.returncode == 0 and fs == [], fs)


def t_gcp_clean():
    tmp = tempfile.mkdtemp(prefix="gg-clean-")
    inv = os.path.join(tmp, "inventory")
    w = lambda n, o: gglib.write_json(os.path.join(inv, n), o)
    w("iam-policy.json", {"bindings": [{"role": "roles/viewer", "members": ["group:ops@example.com"]},
                                       {"role": "roles/editor", "members": [f"serviceAccount:{FX.GG_SA}"]}]})
    w(os.path.join("sa-keys", f"{FX.GG_SA}.json"), [{"name": "k/abc", "validAfterTime": FX.OLD}])
    w("firewalls.json", [FX.FIREWALLS[3]])
    w("networks.json", [{"name": "vpc-main"}])
    w("subnets.json", [{"name": "s1", "logConfig": {"enable": True}}])
    w("buckets.json", [{"name": "b", "uniform_bucket_level_access": True, "public_access_prevention": "enforced", "versioning_enabled": True}])
    w(os.path.join("bucket-iam", "b.json"), {"bindings": []})
    w("sql.json", [{"name": "db", "settings": {"ipConfiguration": {"ipv4Enabled": False, "sslMode": "ENCRYPTED_ONLY"},
                                               "backupConfiguration": {"enabled": True}}}])
    w("project-info.json", {"commonInstanceMetadata": {"items": [{"key": "enable-oslogin", "value": "TRUE"}]}})
    w("instances.json", [{"name": "vm", "zone": "z/asia-east1-b", "serviceAccounts": [{"email": FX.APP_SA, "scopes": []}],
                          "metadata": {"items": []}, "networkInterfaces": [{}], "shieldedInstanceConfig": {"enableSecureBoot": True}}])
    w("clusters.json", [{"name": "c", "location": "l", "masterAuthorizedNetworksConfig": {"enabled": True, "cidrBlocks": [{"cidrBlock": "10.0.0.0/8"}]},
                         "privateClusterConfig": {"enablePrivateNodes": True}, "workloadIdentityConfig": {"workloadPool": "p.svc.id.goog"},
                         "networkConfig": {"datapathProvider": "ADVANCED_DATAPATH"}, "shieldedNodes": {"enabled": True},
                         "releaseChannel": {"channel": "STABLE"}, "masterAuth": {"clusterCaCertificate": "Q0E="}}])
    w(os.path.join("nodepools", "c.json"), [{"name": "np", "config": {"serviceAccount": FX.APP_SA,
                                                                    "shieldedInstanceConfig": {"enableSecureBoot": True},
                                                                    "workloadMetadataConfig": {"mode": "GKE_METADATA"}},
                                             "management": {"autoUpgrade": True, "autoRepair": True}}])
    fs = gcp_rules.scan(inv, FX.GG_SA)
    ok("GCP 規則:乾淨盤點只有資訊(gcp-guardian 自己的金鑰)", [f["rule_id"] for f in fs] == ["GCP-KEY-INFO"], [f["rule_id"] for f in fs])
    shutil.rmtree(tmp, ignore_errors=True)


# ------------------------------------------------------------------ 端到端(假 gcloud / kubectl)

def t_review(e):
    e.clear_log()
    r = e.run([os.path.join(S, "collect.sh"), FX.P])
    run = run_dir(r.stdout)
    ok("審查:collect.sh 完成", r.returncode == 0 and run, r.stderr[-1500:])
    if not run:
        return None
    fs = json.load(open(os.path.join(run, "findings.json")))
    got = sorted(f["rule_id"] for f in fs)
    ok("審查:findings 與預期完全一致", got == FX.EXPECTED_REVIEW,
       f"多:{sorted(set(got) - set(FX.EXPECTED_REVIEW))} 少:{sorted(set(FX.EXPECTED_REVIEW) - set(got))} got={got}")
    bad = []
    for line in open(os.path.join(run, "inventory", "commands.log")):
        rec = json.loads(line)
        try:
            gglib.check_read(rec["argv"], "read")
        except gglib.Denied as ex:
            bad.append(str(ex))
    ok("審查:commands.log 每行都符合唯讀白名單", not bad, bad[:3])
    calls = e.stub_calls()
    home_gc = os.path.join(os.environ.get("HOME", ""), ".config", "gcloud")
    ok("審查:所有呼叫用 run 目錄的隔離 CLOUDSDK_CONFIG / KUBECONFIG",
       calls and all(c["CLOUDSDK_CONFIG"].startswith(run) and c["KUBECONFIG"].startswith(run) for c in calls)
       and not any(c["CLOUDSDK_CONFIG"].startswith(home_gc) for c in calls))
    ok("審查:結束後 run 目錄沒有 gcloud/ 與 kubeconfig", not os.path.exists(os.path.join(run, "gcloud")) and not os.path.exists(os.path.join(run, "kubeconfig")))
    blob = ""
    for root, _, fns in os.walk(run):
        for fn in fns:
            blob += open(os.path.join(root, fn), encoding="utf-8", errors="ignore").read()
    leaks = [x for x in (FX.FAKE_AKIA, FX.FAKE_AIZA, "hunter2", FX.FAKE_CERT, e.key) if x in blob]
    ok("審查:run 目錄沒有任何秘密原文與金鑰路徑", not leaks, leaks)
    ok("審查:metadata 布林值保留(serial-port-enable=TRUE)", '"serial-port-enable",\n          "value": "TRUE"' in blob or '"value": "TRUE"' in blob)
    sec = json.load(open(os.path.join(run, "inventory", "k8s", "prod", "secrets.json")))
    ok("審查:Secret 只有 metadata 與 key 名稱", sec["items"] == [{"namespace": "shop", "name": "db", "type": "Opaque", "keys": ["password"]}], sec)
    r2 = e.run(["node", os.path.join(S, "render.mjs"), "--check", run])
    ok("審查:render --check 通過", r2.returncode == 0, r2.stderr)
    und = json.load(open(os.path.join(run, "inventory", "undetermined.json")))
    ok("審查:沒有無法判定", und == [], und)
    return run


def t_activate_fail(e):
    e.state({"activate_fail": True})
    r = e.run([os.path.join(S, "collect.sh"), FX.P])
    runs = [os.path.join(dp, d) for dp, ds, _ in os.walk(e.reports) for d in ds if d == "gcloud" or d.endswith("kubeconfig")]
    kc = [os.path.join(dp, f) for dp, _, fs in os.walk(e.reports) for f in fs if f == "kubeconfig"]
    ok("SA 啟用失敗 → BLOCKED,run 目錄不殘留 gcloud/ 與 kubeconfig", r.returncode == 3 and not runs and not kc, (r.stderr, runs, kc))
    e.state({})


def t_undetermined(e):
    fx = [f for f in FX.review_fixtures() if not f["re"].startswith("^sql instances list")]
    fx.append({"tool": "gcloud", "re": "^sql instances list", "rc": 1, "err": "ERROR: API [sqladmin.googleapis.com] not enabled"})
    e.set_fixtures(fx)
    r = e.run([os.path.join(S, "collect.sh"), FX.P, "--scope", "sql,iam"])
    run = run_dir(r.stdout)
    und = json.load(open(os.path.join(run, "inventory", "undetermined.json"))) if run else []
    meta_ok = run and "ISSUES" in open(os.path.join(run, "report.html")).read()
    ok("無法判定:API 未啟用列入無法判定且不中斷、狀態不是 PASS",
       r.returncode == 0 and any("sqladmin" in u["error"] for u in und) and meta_ok, (r.stderr, und))
    e.set_fixtures(FX.review_fixtures())


def plan_fixtures():
    P = FX.P
    fx = FX.review_fixtures()
    nodes = lambda n: {"items": [{"metadata": {"name": f"n{i}"}} for i in range(n)]}
    fx = [
        {"tool": "gcloud", "re": "^storage buckets remove-iam-policy-binding gs://public-assets --member=allUsers", "out": {},
         "set": {"bucket_public": False}},
        {"tool": "gcloud", "re": "^compute firewall-rules describe allow-ssh ", "out": FX.FIREWALLS[0]},
        {"tool": "gcloud", "re": "^compute firewall-rules update allow-ssh ", "rc": 1, "err": "ERROR: simulated failure"},
        {"tool": "gcloud", "re": "^container clusters describe prod ", "out": FX.CLUSTER},
        {"tool": "gcloud", "re": "^container node-pools describe default-pool ", "out": FX.NODEPOOLS[0]},
        {"tool": "kubectl", "re": " get nodes -l cloud.google.com/gke-nodepool=default-pool", "when": {"resized": None}, "out": nodes(4)},
        {"tool": "kubectl", "re": " get nodes -l cloud.google.com/gke-nodepool=default-pool", "when": {"resized": True}, "out": nodes(6)},
        {"tool": "gcloud", "re": "^container clusters resize prod ", "out": {}, "set": {"resized": True}},
        {"tool": "kubectl", "re": " get deployment web -n shop -o json", "out": FX.DEPLOY},
        {"tool": "kubectl", "re": " get configmap new-cm -n shop -o json", "rc": 1, "err": 'Error from server (NotFound): configmaps "new-cm" not found'},
        {"tool": "kubectl", "re": " diff -f ", "when": {"diff": "modify"}, "rc": 1,
         "out": "diff -u -N /tmp/LIVE-1/apps.v1.Deployment.shop.web /tmp/MERGED-1/apps.v1.Deployment.shop.web\n--- /tmp/LIVE-1/x\n+++ /tmp/MERGED-1/x\n@@ -10,7 +10,7 @@\n-  replicas: 2\n+  replicas: 3\n"},
        {"tool": "kubectl", "re": " diff -f ", "when": {"diff": "create"}, "rc": 1,
         "out": "diff -u -N /tmp/LIVE-1/v1.ConfigMap.shop.new-cm /tmp/MERGED-1/v1.ConfigMap.shop.new-cm\n--- /tmp/LIVE-1/x\n+++ /tmp/MERGED-1/x\n@@ -0,0 +1,6 @@\n+kind: ConfigMap\n"},
        {"tool": "kubectl", "re": " apply --dry-run=server -o json -f ", "when": {"dry": "privileged"},
         "out": _priv_deploy()},
        {"tool": "kubectl", "re": " apply --dry-run=server -o json -f ", "out": {"kind": "ConfigMap", "metadata": {"name": "new-cm", "namespace": "shop"}}},
    ] + fx
    return fx


def _priv_deploy():
    d = copy.deepcopy(FX.DEPLOY)
    d["spec"]["template"]["spec"]["containers"][0]["securityContext"] = {"privileged": True}
    return d


def write_input(run, items):
    with open(os.path.join(run, "plan.input.json"), "w") as f:
        json.dump({"items": items}, f, ensure_ascii=False)


def plan_build(e, run):
    r = e.run([os.path.join(S, "plan.py"), "build", run])
    sha = None
    for line in r.stdout.splitlines():
        if line.startswith("sha256="):
            sha = line[7:]
    return r, sha


def t_plan_change(e, review_run):
    P = FX.P
    e.set_fixtures(plan_fixtures())
    e.state({})
    run = review_run
    write_input(run, [
        {"id": "C1", "summary": "移除 bucket 公開讀取", "finding": "GCS-PUB-001",
         "command": ["gcloud", "storage", "buckets", "remove-iam-policy-binding", "gs://public-assets", "--member=allUsers",
                     "--role=roles/storage.objectViewer", f"--project={P}"],
         "expected": [{"field": "/bindings", "expect": []}], "impact": "無"},
        {"id": "C2", "summary": "SSH 只允許 IAP", "command": ["gcloud", "compute", "firewall-rules", "update", "allow-ssh",
                                                           f"--project={P}", "--source-ranges=35.235.240.0/20"],
         "expected": [{"field": "/sourceRanges", "expect": ["35.235.240.0/20"]}], "impact": "非 IAP 的 SSH 會斷"},
        {"id": "C3", "summary": "default-pool 每區 2→3 台", "command": ["gcloud", "container", "clusters", "resize", "prod",
                                                                    "--node-pool=default-pool", "--num-nodes=3", "--location=asia-east1", f"--project={P}"],
         "expected": [{"field": "/node_count_per_zone", "expect": 3}], "impact": "無"},
        {"id": "C5", "summary": "別的專案的 bucket", "command": ["gcloud", "storage", "buckets", "update", "gs://other-proj-data", f"--project={P}", "--versioning"],
         "expected": [{"field": "/versioning_enabled", "expect": True}]},
        {"id": "C4", "summary": "開 security posture(agent 謊報可還原)", "reversible": True, "rollback": ["echo"],
         "loosens_security": False,
         "command": ["gcloud", "container", "clusters", "update", "prod", "--location=asia-east1", f"--project={P}", "--security-posture=enterprise"],
         "expected": [{"field": "/securityPostureConfig/mode", "expect": "ENTERPRISE"}]},
    ])
    r, sha = plan_build(e, run)
    plan_path = os.path.join(run, "plan.json")
    plan = json.load(open(plan_path)) if os.path.exists(plan_path) else {"items": []}
    by = {i["id"]: i for i in plan["items"]}
    ok("計畫:plan.py build 產出 plan.json 與 sha256", sha and sha == gglib.sha256_file(plan_path), r.stderr[-1500:])
    ok("計畫:C1–C3 可執行、C4 被判不可還原(忽略 agent 給的 reversible=true)",
       by and not by["C1"]["blocked_reason"] and not by["C2"]["blocked_reason"] and not by["C3"]["blocked_reason"]
       and by["C4"]["reversible"] is False and by["C4"]["blocked_reason"], json.dumps(by, ensure_ascii=False)[:1500])
    ok("計畫:不屬於本專案的 bucket → BLOCKED", by.get("C5", {}).get("blocked_reason") and "不屬於" in by["C5"]["blocked_reason"], by.get("C5"))
    ok("計畫:還原指令由 kit 產生(C2 還原回 0.0.0.0/0、C3 回 2 台)",
       by and "--source-ranges=0.0.0.0/0" in by["C2"]["rollback"] and "--num-nodes=2" in by["C3"]["rollback"])
    r2 = e.run(["node", os.path.join(S, "render.mjs"), "--check", run])
    ok("計畫:報告含 plan sha256 且 --check 通過", r2.returncode == 0 and sha in open(os.path.join(run, "report.html")).read(), r2.stderr)
    exec_re = ("remove-iam-policy-binding", "firewall-rules update", "clusters resize", "clusters update")

    def execs():
        return [" ".join(c["argv"]) for c in e.stub_calls() if any(x in " ".join(c["argv"]) for x in exec_re)]

    ch = os.path.join(S, "change.sh")
    e.clear_log()
    r = e.run([ch, plan_path, "--sha", "0" * 64, "--approved", "使用者已核准變更 C1"])
    ok("變更:plan sha256 不符 → BLOCKED,零變更呼叫", r.returncode == 3 and "status=BLOCKED" in r.stdout and not execs(), r.stdout + r.stderr)
    e.clear_log()
    r = e.run([ch, plan_path, "--sha", sha, "--approved", "請幫我做 C1"])
    ok("變更:沒有核准旗標 → BLOCKED", r.returncode == 3 and not execs(), r.stdout + r.stderr)
    e.clear_log()
    r = e.run([ch, plan_path, "--sha", sha, "--approved", "使用者已核准變更 C2, C3"])
    ex = execs()
    ok("變更:C2 失敗 → ISSUES,C3 未執行(沒有 resize 呼叫)",
       r.returncode == 1 and "C3\t未執行" in r.stdout and not any("resize" in x for x in ex) and any("firewall-rules update" in x for x in ex),
       r.stdout + r.stderr + str(ex))
    crun = run_dir(r.stdout)
    ok("變更:change-log.md 由 kit 產生,before/ 有紀錄", crun and os.path.exists(os.path.join(crun, "change-log.md"))
       and os.path.exists(os.path.join(crun, "before", "C2.json")))
    e.clear_log()
    r = e.run([ch, plan_path, "--sha", sha, "--approved", "使用者已核准變更 C1"])
    ex = execs()
    crun = run_dir(r.stdout)
    ok("變更:只核准 C1 → PASS,只呼叫 C1(未核准零呼叫)",
       r.returncode == 0 and "status=PASS" in r.stdout and len(ex) == 1 and "remove-iam-policy-binding" in ex[0], r.stdout + r.stderr + str(ex))
    ok("變更:回報 C1 還原指令(add-iam-policy-binding allUsers)", "add-iam-policy-binding" in r.stdout)
    if crun:
        r2 = e.run(["node", os.path.join(S, "render.mjs"), "--check", crun])
        ok("變更:變更 run 的 --check 通過", r2.returncode == 0, r2.stderr)
    e.clear_log()
    r = e.run([ch, plan_path, "--sha", sha, "--approved", "使用者已核准變更 C1"])
    ok("變更:環境已變(precondition 不符)→ BLOCKED,零變更呼叫", r.returncode == 3 and "precondition" in r.stdout and not execs(), r.stdout + r.stderr)
    e.clear_log()
    r = e.run([ch, plan_path, "--sha", sha, "--approved", "使用者已核准變更 C4"])
    ok("變更:計畫中 BLOCKED 的條目 → BLOCKED", r.returncode == 3 and not execs(), r.stdout + r.stderr)
    # 手改 plan.json 的 reversible 並重算雜湊
    edited = copy.deepcopy(plan)
    for it in edited["items"]:
        if it["id"] == "C4":
            it["reversible"], it["blocked_reason"], it["rollback"] = True, None, ["gcloud", "echo"]
            it["kind"], it["target"] = "gke-cluster-update", {"project": P}
    erun = run + "-edited"
    os.makedirs(erun)
    shutil.copy(os.path.join(run, "meta.json"), os.path.join(erun, "meta.json"))
    edited["source_run"] = erun
    ep = os.path.join(erun, "plan.json")
    with open(ep, "w") as f:
        f.write(json.dumps(edited, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    e.clear_log()
    r = e.run([ch, ep, "--sha", gglib.sha256_file(ep), "--approved", "使用者已核准變更 C4"])
    ok("變更:手改 plan.json 的 reversible 並重算雜湊 → change.sh 重算後 BLOCKED",
       r.returncode == 3 and not execs() and ("重新" in r.stdout or "不可還原" in r.stdout), r.stdout + r.stderr)
    # 專案鎖被佔用(另一個程序持有 flock)
    import fcntl
    os.makedirs(os.path.join(e.reports, P), exist_ok=True)
    lf = os.open(os.path.join(e.reports, P, ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(lf, fcntl.LOCK_EX)
    os.pwrite(lf, json.dumps({"mode": "change", "run": "/other"}).encode(), 0)
    e.clear_log()
    e.state({})
    r = e.run([ch, plan_path, "--sha", sha, "--approved", "使用者已核准變更 C1"])
    ok("變更:專案鎖被佔用 → BLOCKED", r.returncode == 3 and "鎖" in (r.stdout + r.stderr) and not execs(), r.stdout + r.stderr)
    os.close(lf)
    # 偽造計畫:拿 agent 可寫的 plan.input.json 當計畫
    fake = os.path.join(run, "plan.input.json")
    e.clear_log()
    r = e.run([ch, fake, "--sha", gglib.sha256_file(fake), "--approved", "使用者已核准變更 C1"])
    ok("變更:非 plan.py 產生的 plan.json(plan.input.json)→ BLOCKED", r.returncode == 3 and not execs(), r.stdout + r.stderr)
    # k8s:endpoint 不符、apply 新建、apply privileged
    CTX = f"gke_{P}_asia-east1_prod"
    r = e.run([os.path.join(S, "collect.sh"), P, "--mode", "plan", "--scope", "gke"])
    krun = run_dir(r.stdout)
    write_input(krun, [
        {"id": "C1", "summary": "web 2→3", "command": ["kubectl", f"--context={CTX}", "scale", "deployment/web", "--namespace=shop", "--replicas=3"],
         "expected": [{"field": "/spec/replicas", "expect": 3}]},
        {"id": "C2", "summary": "新增 configmap", "command": ["kubectl", f"--context={CTX}", "apply", "--filename=<manifest>"],
         "manifest": "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: new-cm\n  namespace: shop\ndata:\n  a: b\n",
         "expected": [{"field": "/objects/0/data/a", "expect": "b"}]},
    ])
    e.state({"diff": "create"})
    r, ksha = plan_build(e, krun)
    kp = json.load(open(os.path.join(krun, "plan.json")))
    kb = {i["id"]: i for i in kp["items"]}
    ok("計畫 k8s:scale 可執行(記錄 endpoint)、apply 新建資源 → 不可還原 BLOCKED",
       not kb["C1"]["blocked_reason"] and kb["C1"]["target"].get("endpoint") == "https://10.0.0.1"
       and kb["C2"]["reversible"] is False and kb["C2"]["blocked_reason"], json.dumps(kb, ensure_ascii=False)[:1500])
    e.state({"diff": "create", "endpoint": ""})
    r, _ = plan_build(e, krun)
    kb0 = {i["id"]: i for i in json.load(open(os.path.join(krun, "plan.json")))["items"]}
    ok("計畫 k8s:讀不到叢集 endpoint → BLOCKED", kb0["C1"]["blocked_reason"] and "endpoint" in kb0["C1"]["blocked_reason"], kb0["C1"])
    e.state({"diff": "create"})
    r, ksha = plan_build(e, krun)
    e.state({"endpoint": "https://10.9.9.9"})
    e.clear_log()
    r = e.run([ch, os.path.join(krun, "plan.json"), "--sha", ksha, "--approved", "使用者已核准變更 C1"])
    ok("變更 k8s:叢集 endpoint 與計畫不符 → BLOCKED,沒有 scale 呼叫",
       r.returncode == 3 and "endpoint" in r.stdout and not any(" scale " in " ".join(c["argv"]) for c in e.stub_calls()), r.stdout + r.stderr)
    write_input(krun, [
        {"id": "C1", "summary": "web 改成 privileged", "command": ["kubectl", f"--context={CTX}", "apply", "--filename=<manifest>"],
         "manifest": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\n",
         "expected": [{"field": "/objects/0/spec/replicas", "expect": 2}]},
    ])
    e.state({"diff": "modify", "dry": "privileged"})
    r, _ = plan_build(e, krun)
    kp = json.load(open(os.path.join(krun, "plan.json")))
    it = kp["items"][0]
    ok("計畫 k8s:apply 後會變 privileged → BLOCKED", it["blocked_reason"] and "K8S-PRIV-001" in it["blocked_reason"], it)
    raw = open(os.path.join(krun, "plan.json")).read()
    outs = [l.get("out", "") for l in it.get("dry_run_log", [])]
    ok("計畫 k8s:plan.json 不保留 kubectl diff 內容(只留資源與新建 / 修改)",
       "replicas: 3" not in raw and "apps.v1.Deployment.shop.web\t修改" in outs, outs)
    write_input(krun, [
        {"id": "C1", "summary": "改 web(合法)", "command": ["kubectl", f"--context={CTX}", "apply", "--filename=<manifest>"],
         "manifest": "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: web\n  namespace: shop\n",
         "expected": [{"field": "/objects/0/spec/replicas", "expect": 2}]},
        {"id": "C2", "summary": "manifest 夾帶 Secret", "command": ["kubectl", f"--context={CTX}", "apply", "--filename=<manifest>"],
         "manifest": "apiVersion: v1\nkind: Secret\nmetadata:\n  name: db\n  namespace: shop\nstringData:\n  a: b\n",
         "expected": [{"field": "/objects/0/type", "expect": "Opaque"}]},
        {"id": "C3", "summary": "patch 大寫 Secret", "command": ["kubectl", f"--context={CTX}", "patch", "Secret", "db", "--namespace=shop", "--type=merge", "--patch-file=<patch>"],
         "patch": "{\"data\": {}}", "expected": [{"field": "/type", "expect": "Opaque"}]},
    ])
    e.state({"diff": "modify"})
    e.clear_log()
    r, _ = plan_build(e, krun)
    kb = {i["id"]: i for i in json.load(open(os.path.join(krun, "plan.json")))["items"]}
    secret_calls = [c for c in e.stub_calls() if c["tool"] == "kubectl" and any("secret" in a.lower() for a in c["argv"])]
    ok("計畫 k8s:Secret 相關條目 BLOCKED、整份計畫照常產出、沒有任何讀 Secret 的 kubectl 呼叫",
       r.returncode in (0, 1) and kb["C2"]["blocked_reason"] and kb["C3"]["blocked_reason"] and not kb["C1"]["blocked_reason"] and not secret_calls,
       (r.stderr[-600:], {k: v["blocked_reason"] for k, v in kb.items()}, secret_calls))
    ok("計畫 k8s:apply 的還原指令是 kubectl replace before/C1.rollback.json",
       "replace" in kb["C1"]["rollback"] and any(a.endswith("/before/C1.rollback.json") for a in kb["C1"]["rollback"]), kb["C1"]["rollback"])
    write_input(krun, [{"id": "C1", "summary": "manifest 指到外部檔", "command": ["kubectl", f"--context={CTX}", "apply", "--filename=/tmp/x/manifests/C1.yaml"],
                        "expected": [{"field": "/objects/0/spec/replicas", "expect": 2}]}])
    r, _ = plan_build(e, krun)
    it = json.load(open(os.path.join(krun, "plan.json")))["items"][0]
    ok("計畫 k8s:--filename 不是占位(外部檔不受 sha256 涵蓋)→ BLOCKED", it["blocked_reason"] and "占位" in it["blocked_reason"], it["blocked_reason"])


def t_wrapper(e):
    cfg = gglib.load_config(require=False)
    cfg["GG_SA_KEY_FILE"] = e.key
    s = gglib.Session(cfg, e.tmp, FX.P, "read")
    for name, argv in (("gcloud 缺 --project", ["gcloud", "projects", "list", "--format=json", "--quiet"]),
                       ("kubectl 缺 --context", ["kubectl", "get", "pods", "-A", "-o", "json"]),
                       ("變更指令走唯讀模式", ["gcloud", "compute", "firewall-rules", "update", "x", f"--project={FX.P}"])):
        try:
            s._exec(argv, "read")
            ok(f"包裝拒絕:{name}", False)
        except gglib.Denied:
            ok(f"包裝拒絕:{name}", True)
    try:
        s._exec(["gcloud", "compute", "instances", "delete", "vm1", f"--project={FX.P}"], "change")
        ok("包裝拒絕:變更模式的禁止動詞(第二道防線)", False)
    except gglib.Denied:
        ok("包裝拒絕:變更模式的禁止動詞(第二道防線)", True)


def main():
    e = Env()
    try:
        t_allowlists()
        t_guard(e)
        t_redact()
        t_rule_tables()
        t_yaml_bool()
        t_misc()
        t_approve_parse()
        t_classify()
        t_wrapper(e)
        t_gcp_clean()
        t_yaml(e)
        run = t_review(e)
        t_undetermined(e)
        t_activate_fail(e)
        if run:
            t_plan_change(e, run)
    finally:
        e.close()
    fails = [n for n, c in RESULTS if not c]
    print(f"\n{len(RESULTS) - len(fails)}/{len(RESULTS)} PASS")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
