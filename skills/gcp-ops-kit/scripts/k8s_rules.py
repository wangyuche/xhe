"""k8s 規則(YAML 審查、線上叢集、變更前 dry-run 結果共用)。

用法(命令列):python3 k8s_rules.py <yaml2json 輸出.json>  → findings JSON 陣列到 stdout
每條規則固定嚴重度(RULES 表);selftest 檢查每條都有標。
"""
import json
import re
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.realpath(__file__)))

import gglib

RULES = {
    "K8S-PRIV-001": ("高", "容器以 privileged 執行", "移除 securityContext.privileged 或設為 false"),
    "K8S-HOST-001": ("高", "Pod 使用 hostNetwork / hostPID / hostIPC", "移除 hostNetwork / hostPID / hostIPC"),
    "K8S-HOST-002": ("高", "Pod 掛載 hostPath", "改用 emptyDir / PVC / ConfigMap,不要掛主機路徑"),
    "K8S-CAP-001": ("高", "容器加入危險 capability(SYS_ADMIN、NET_ADMIN、ALL 等)", "移除 capabilities.add 裡的危險項,改 drop: [ALL]"),
    "K8S-SEC-001": ("嚴重", "Secret 的值直接寫在 YAML(會進版控)", "改用 Secret Manager + External Secrets / CSI driver,或 sealed-secrets;已進版控的值要輪替"),
    "K8S-SEC-002": ("高", "容器 env 以明文寫入疑似秘密", "改用 valueFrom.secretKeyRef,並輪替已外露的值"),
    "K8S-RBAC-001": ("高", "Role / ClusterRole 使用萬用字元 *", "列出實際需要的 apiGroups / resources / verbs"),
    "K8S-RBAC-002": ("高", "非系統主體綁定 cluster-admin", "改綁最小權限的 Role / ClusterRole"),
    "K8S-ROOT-001": ("中", "容器可能以 root 執行(未設 runAsNonRoot 或 runAsUser=0)", "設 securityContext.runAsNonRoot: true 與非 0 的 runAsUser"),
    "K8S-PE-001": ("中", "未禁止權限提升(allowPrivilegeEscalation 不是 false)", "設 securityContext.allowPrivilegeEscalation: false"),
    "K8S-CAP-002": ("中", "容器加入 capability", "確認必要性,預設 drop: [ALL]"),
    "K8S-RES-001": ("中", "容器缺 resources requests / memory limit", "設 resources.requests.cpu / memory 與 limits.memory"),
    "K8S-IMG-001": ("中", "映像用 :latest 或沒有 tag / digest", "固定版本 tag,最好用 @sha256 digest"),
    "K8S-NP-001": ("中", "範圍內沒有任何 NetworkPolicy", "每個 namespace 加 default-deny 與必要的允許規則"),
    "K8S-LB-001": ("中", "LoadBalancer Service 沒有限制來源網段", "設 spec.loadBalancerSourceRanges,或改內部 LB / Ingress + Cloud Armor"),
    "K8S-ROFS-001": ("低", "容器根檔案系統可寫", "設 securityContext.readOnlyRootFilesystem: true,需要寫入的路徑掛 emptyDir"),
    "K8S-PROBE-001": ("低", "長駐容器缺 readiness / liveness probe", "加 readinessProbe 與 livenessProbe"),
    "K8S-SA-001": ("低", "Pod 自動掛載 ServiceAccount token", "不需要呼叫 API 時設 automountServiceAccountToken: false"),
    "K8S-PSA-001": ("低", "Namespace 缺 Pod Security enforce 標籤", "加 pod-security.kubernetes.io/enforce: restricted(或 baseline)"),
}

import os as _os
with open(_os.path.join(gglib.RULES_DIR, "allow_change.json"), encoding="utf-8") as _f:
    SYSTEM_NS = re.compile(json.load(_f)["system_namespaces"])  # 與變更規則共用同一份系統 namespace 清單
DANGEROUS_CAPS = {"ALL", "SYS_ADMIN", "NET_ADMIN", "SYS_PTRACE", "SYS_MODULE", "DAC_READ_SEARCH", "NET_RAW", "BPF", "SYS_RAWIO"}
WORKLOAD_KINDS = {"Pod", "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job", "CronJob", "ReplicationController"}
LONG_RUNNING = {"Deployment", "StatefulSet", "DaemonSet", "ReplicationController"}


def _d(x):
    return x if isinstance(x, dict) else {}


def pod_spec(obj):
    k = obj.get("kind")
    s = _d(obj.get("spec"))
    if k == "Pod":
        return s, "/spec"
    if k == "CronJob":
        return _d(_d(_d(_d(s.get("jobTemplate")).get("spec")).get("template")).get("spec")), "/spec/jobTemplate/spec/template/spec"
    if k in WORKLOAD_KINDS:
        return _d(_d(s.get("template")).get("spec")), "/spec/template/spec"
    return None, None


class Ctx:
    def __init__(self, source, live):
        self.source, self.live = source, live
        self.out = []

    def add(self, rule, doc, path, detail="", value=None):
        sev, title, fix = RULES[rule]
        obj = doc["obj"]
        md = _d(obj.get("metadata"))
        res = f"{obj.get('kind')}/{md.get('namespace', '-') if obj.get('kind') not in ('Namespace', 'ClusterRole', 'ClusterRoleBinding') else '-'}/{md.get('name')}"
        ev = {"file": doc.get("file"), "path": path}
        if doc.get("lines"):
            ev["line"] = nearest_line(doc["lines"], path) or doc.get("line")
        elif doc.get("index") is not None:
            ev["index"] = doc["index"]
        if value is not None:
            ev["value"] = value
        self.out.append({
            "rule_id": rule, "severity": sev, "title": title, "detail": detail,
            "resource": res, "evidence": ev, "fix": fix, "cis": None, "source": "rule",
            "context": doc.get("context"),
        })


def nearest_line(lines, path):
    p = path
    while p:
        if p in lines:
            return lines[p]
        p = p.rsplit("/", 1)[0]
    return lines.get("/")


def owned(obj):
    return bool(_d(obj.get("metadata")).get("ownerReferences"))


def scan(docs, live=False):
    """docs:[{obj, file, line?, lines?, index?, context?}]。live=True 時略過系統 namespace 與被控制器擁有的 Pod / RS / Job。"""
    c = Ctx(None, live)
    namespaces_with_workloads, namespaces_with_np, ns_objs, first_workload = set(), set(), {}, {}
    for doc in docs:
        obj = _d(doc.get("obj"))
        kind = obj.get("kind")
        md = _d(obj.get("metadata"))
        ns = md.get("namespace") or "default"
        if kind == "Namespace":
            ns_objs[md.get("name")] = doc
            continue
        if live and SYSTEM_NS.match(ns or ""):
            continue
        if kind == "NetworkPolicy":
            namespaces_with_np.add(ns)
        if kind == "Secret" and not live:
            for fld in ("data", "stringData"):
                if obj.get(fld):
                    c.add("K8S-SEC-001", doc, f"/{fld}", f"{len(obj[fld])} 個 key:{', '.join(sorted(obj[fld]))}")
        if kind in ("Role", "ClusterRole"):
            for i, r in enumerate(obj.get("rules") or []):
                for fld in ("verbs", "resources", "apiGroups"):
                    if "*" in (r.get(fld) or []):
                        if live and (md.get("name", "").startswith("system:") or md.get("name") in ("cluster-admin", "admin", "edit")):
                            continue
                        c.add("K8S-RBAC-001", doc, f"/rules/{i}/{fld}", f"{fld} 含 *")
                        break
        if kind in ("ClusterRoleBinding", "RoleBinding"):
            if (obj.get("roleRef") or {}).get("name") == "cluster-admin":
                for i, s in enumerate(obj.get("subjects") or []):
                    nm = s.get("name", "")
                    if nm.startswith("system:"):
                        continue  # 只依主體排除系統帳號 / 群組;不看 binding 名稱(名稱可以任意取)
                    c.add("K8S-RBAC-002", doc, f"/subjects/{i}", f"{s.get('kind')} {nm}")
        if kind == "Service" and (obj.get("spec") or {}).get("type") == "LoadBalancer":
            sp = obj["spec"]
            ann = md.get("annotations") or {}
            internal = any("internal" in k and str(v).lower() in ("true", "internal") for k, v in ann.items()) or \
                str(ann.get("networking.gke.io/load-balancer-type", "")).lower() == "internal" or \
                str(ann.get("cloud.google.com/load-balancer-type", "")).lower() == "internal"
            if not internal and not sp.get("loadBalancerSourceRanges"):
                c.add("K8S-LB-001", doc, "/spec/type")
        spec, base = pod_spec(obj)
        if spec is None:
            continue
        if live and kind in ("Pod", "ReplicaSet", "Job") and owned(obj):
            continue
        namespaces_with_workloads.add(ns)
        first_workload.setdefault(ns, doc)
        _pod_checks(c, doc, spec, base, kind)
    # NetworkPolicy:YAML 審查看整個範圍;線上看每個有 workload 的 namespace
    if live:
        for ns in sorted(namespaces_with_workloads - namespaces_with_np):
            c.add("K8S-NP-001", first_workload[ns], "/metadata/namespace", f"namespace {ns} 有 workload 但沒有 NetworkPolicy")
    elif namespaces_with_workloads and not namespaces_with_np:
        first = next(d for d in docs if pod_spec(d.get("obj") or {})[0] is not None)
        c.add("K8S-NP-001", first, "/", "掃描範圍內有 workload,但沒有任何 NetworkPolicy")
    for name, doc in ns_objs.items():
        if live and SYSTEM_NS.match(name or ""):
            continue
        labels = _d(_d(doc["obj"].get("metadata")).get("labels"))
        if "pod-security.kubernetes.io/enforce" not in labels:
            c.add("K8S-PSA-001", doc, "/metadata/labels" if labels else "/metadata")
    return c.out


def _pod_checks(c, doc, spec, base, kind):
    for fld in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(fld) is True:
            c.add("K8S-HOST-001", doc, f"{base}/{fld}", fld)
    for i, v in enumerate(spec.get("volumes") or []):
        if "hostPath" in v:
            c.add("K8S-HOST-002", doc, f"{base}/volumes/{i}/hostPath", (v.get("hostPath") or {}).get("path", ""))
    if spec.get("automountServiceAccountToken") is not False:
        c.add("K8S-SA-001", doc, f"{base}/automountServiceAccountToken" if "automountServiceAccountToken" in spec else base)
    psc = spec.get("securityContext") or {}
    for group in ("initContainers", "containers"):
        for i, ct in enumerate(spec.get(group) or []):
            cp = f"{base}/{group}/{i}"
            sc = ct.get("securityContext") or {}
            name = ct.get("name", "")
            if sc.get("privileged") is True:
                c.add("K8S-PRIV-001", doc, f"{cp}/securityContext/privileged", name)
            caps = ((sc.get("capabilities") or {}).get("add") or [])
            bad = [x for x in caps if str(x).upper().replace("CAP_", "") in DANGEROUS_CAPS]
            if bad:
                c.add("K8S-CAP-001", doc, f"{cp}/securityContext/capabilities/add", f"{name}: {', '.join(bad)}")
            elif caps:
                c.add("K8S-CAP-002", doc, f"{cp}/securityContext/capabilities/add", f"{name}: {', '.join(map(str, caps))}")
            non_root = sc.get("runAsNonRoot", psc.get("runAsNonRoot"))
            uid = sc.get("runAsUser", psc.get("runAsUser"))
            if uid == 0 or (non_root is not True and not (isinstance(uid, int) and uid > 0)):
                c.add("K8S-ROOT-001", doc, f"{cp}/securityContext", name)
            if sc.get("allowPrivilegeEscalation") is not False and sc.get("privileged") is not True:
                c.add("K8S-PE-001", doc, f"{cp}/securityContext", name)
            if group == "containers" and sc.get("readOnlyRootFilesystem") is not True:
                c.add("K8S-ROFS-001", doc, f"{cp}/securityContext", name)
            img = ct.get("image") or ""
            if "@sha256:" not in img:
                last = img.rsplit("/", 1)[-1]
                if ":" not in last or last.endswith(":latest"):
                    c.add("K8S-IMG-001", doc, f"{cp}/image", value=img)
            if group == "containers":
                res = ct.get("resources") or {}
                req, lim = res.get("requests") or {}, res.get("limits") or {}
                missing = [x for x, ok in (("requests.cpu", "cpu" in req), ("requests.memory", "memory" in req),
                                           ("limits.memory", "memory" in lim)) if not ok]
                if missing:
                    c.add("K8S-RES-001", doc, f"{cp}/resources" if res else cp, f"{name} 缺 {', '.join(missing)}")
                if kind in LONG_RUNNING and not (ct.get("readinessProbe") and ct.get("livenessProbe")):
                    c.add("K8S-PROBE-001", doc, cp, name)
            for j, e in enumerate(ct.get("env") or []):
                if "value" not in e:
                    continue
                sec = e.get("looks_secret")
                if sec is None:
                    sec = gglib.looks_secret(e.get("name", ""), e.get("value"))
                if sec:
                    c.add("K8S-SEC-002", doc, f"{cp}/env/{j}/value", f"{name}: {e.get('name')}",
                          value=gglib.redact_value(e["value"]) if not str(e["value"]).startswith("<redacted") else e["value"])


if __name__ == "__main__":
    with open(sys.argv[1], encoding="utf-8") as f:
        docs = json.load(f)
    json.dump(scan(docs, live="--live" in sys.argv), sys.stdout, ensure_ascii=False, indent=1)
