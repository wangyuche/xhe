"""GCP 規則:讀 run 目錄的 inventory/,產生 findings。

用法:python3 gcp_rules.py <inventory 目錄> [--sa <gcp-guardian SA email>] [--now <ISO 時間>]
CIS 編號只標註 CIS GCP Foundations v3.0.0 中有把握的項目;其他為 null。
"""
import datetime
import glob
import json
import os
import re
import sys

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.realpath(__file__)))

RULES = {
    # id: (嚴重度, 標題, 修正方式, CIS)
    "GCP-IAM-001": ("嚴重", "專案 IAM 授權給 allUsers / allAuthenticatedUsers", "移除公開成員的綁定", None),
    "GCP-IAM-002": ("高", "Service Account 擁有 Owner / Editor", "改授予最小權限的預定義角色", "1.5"),
    "GCP-IAM-003": ("中", "使用者帳號直接擁有 Editor", "改用群組 + 預定義角色", None),
    "GCP-IAM-004": ("高", "專案層級授予 Service Account User / Token Creator", "改在個別 SA 上授權", "1.6"),
    "GCP-IAM-005": ("中", "外部網域帳號(gmail.com 等)擁有專案角色", "確認是否為預期成員,改用組織帳號", None),
    "GCP-KEY-001": ("中", "使用者管理的 SA 金鑰超過 90 天", "輪替或改用 Workload Identity / 短效憑證", "1.7"),
    "GCP-KEY-002": ("低", "Service Account 有使用者管理的金鑰", "盡量改用 Workload Identity Federation / 附加 SA", "1.4"),
    "GCP-KEY-INFO": ("資訊", "gcp-guardian 自己的 SA 金鑰(已知)", "依金鑰年齡定期輪替", None),
    "GCP-NET-001": ("高", "防火牆對 0.0.0.0/0 開放 SSH(22)或 RDP(3389)", "限制來源網段,改用 IAP(35.235.240.0/20)", "3.6/3.7"),
    "GCP-NET-002": ("中", "防火牆對 0.0.0.0/0 開放其他埠", "限制來源網段或改經負載平衡器", None),
    "GCP-NET-003": ("低", "專案仍有 default 網路", "建立自訂 VPC 後刪除 default 網路(由使用者執行)", "3.1"),
    "GCP-NET-004": ("低", "子網未啟用 VPC Flow Logs", "啟用 flow logs", "3.8"),
    "GCS-PUB-001": ("嚴重", "Bucket 授權給 allUsers / allAuthenticatedUsers", "移除公開成員,開啟公開存取防護", "5.1"),
    "GCS-UBLA-001": ("中", "Bucket 未啟用統一 bucket 層級存取", "啟用 uniform bucket-level access", "5.2"),
    "GCS-PAP-001": ("低", "Bucket 未強制公開存取防護", "設 public access prevention = enforced", None),
    "GCS-VER-001": ("低", "Bucket 未啟用物件版本", "需要可復原時啟用 versioning", None),
    "SQL-PUB-001": ("嚴重", "Cloud SQL 授權網路含 0.0.0.0/0", "移除 0.0.0.0/0,改私人 IP 或 Cloud SQL Auth Proxy", None),
    "SQL-IP-001": ("高", "Cloud SQL 有公開 IP", "改用私人 IP;必要時限定授權網路", None),
    "SQL-SSL-001": ("高", "Cloud SQL 允許未加密連線", "設 sslMode = ENCRYPTED_ONLY 或 TRUSTED_CLIENT_CERTIFICATE_REQUIRED", None),
    "SQL-BAK-001": ("中", "Cloud SQL 未啟用自動備份", "啟用自動備份與時間點復原", None),
    "GCE-SA-001": ("高", "VM 使用預設 Compute SA 且有 cloud-platform 完整權限", "改用專用 SA 與最小 scope", "4.2"),
    "GCE-SA-002": ("中", "VM 使用預設 Compute SA", "改用專用 SA", "4.1"),
    "GCE-SER-001": ("高", "VM 啟用序列埠連線", "metadata serial-port-enable 設為 false", "4.5"),
    "GCE-OSL-001": ("中", "未啟用 OS Login", "專案 metadata enable-oslogin=TRUE", "4.4"),
    "GCE-SSH-001": ("低", "VM 未封鎖專案層級 SSH 金鑰", "instance metadata block-project-ssh-keys=TRUE", "4.3"),
    "GCE-IPF-001": ("中", "VM 啟用 IP forwarding", "非路由器用途時關閉 canIpForward", "4.6"),
    "GCE-SHV-001": ("低", "VM 未啟用 Shielded VM 安全開機", "啟用 Secure Boot / vTPM / Integrity Monitoring", "4.8"),
    "GCE-IP-001": ("中", "VM 有外部 IP", "改經 Cloud NAT / IAP / 負載平衡器", "4.9"),
    "GKE-CP-001": ("高", "GKE 控制平面對網際網路開放(未啟用授權網路且非私有端點)", "啟用 master authorized networks 或私有端點", None),
    "GKE-CP-002": ("高", "GKE 控制平面授權網路含 0.0.0.0/0", "移除 0.0.0.0/0", None),
    "GKE-BASIC-001": ("高", "GKE 啟用 basic auth 或用戶端憑證", "停用 basic auth 與 client certificate(需重建或遷移)", None),
    "GKE-ABAC-001": ("高", "GKE 啟用 legacy ABAC", "停用 legacy authorization", None),
    "GKE-PRIV-001": ("中", "GKE 節點有公開 IP(非私有節點)", "改用私有節點 + Cloud NAT", None),
    "GKE-WI-001": ("中", "GKE 未啟用 Workload Identity", "啟用 workload pool,Pod 改用 KSA ↔ GSA 綁定", None),
    "GKE-NP-001": ("中", "GKE 未啟用 NetworkPolicy(也非 Dataplane V2)", "啟用 network policy 或 Dataplane V2", None),
    "GKE-SHN-001": ("低", "GKE 未啟用 Shielded GKE Nodes", "啟用 shielded nodes", None),
    "GKE-REL-001": ("低", "GKE 未加入 release channel", "加入 REGULAR / STABLE channel(版本變更由使用者執行)", None),
    "GKE-LOG-001": ("低", "GKE 關閉 Cloud Logging 或 Monitoring", "啟用 SYSTEM / WORKLOAD logging 與 monitoring", None),
    "GKE-NODE-001": ("中", "Node pool 使用預設 Compute SA", "改用最小權限的專用節點 SA", None),
    "GKE-NODE-002": ("低", "Node pool 關閉自動升級", "啟用 auto-upgrade", None),
    "GKE-NODE-003": ("低", "Node pool 關閉自動修復", "啟用 auto-repair", None),
    "GKE-NODE-004": ("中", "Node pool 未啟用 Secure Boot", "啟用 shielded secure boot", None),
    "GKE-NODE-005": ("中", "Node pool 未使用 GKE metadata server", "workload-metadata 設為 GKE_METADATA", None),
}

PUBLIC = ("allUsers", "allAuthenticatedUsers")
CONSUMER_DOMAINS = ("gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "yahoo.com")


class Out:
    def __init__(self, inv):
        self.inv, self.items = inv, []

    def add(self, rule, resource, file, path, detail="", value=None):
        sev, title, fix, cis = RULES[rule]
        ev = {"file": os.path.relpath(file, os.path.dirname(self.inv)) if file else None, "path": path}
        if value is not None:
            ev["value"] = value
        self.items.append({"rule_id": rule, "severity": sev, "title": title, "detail": detail,
                           "resource": resource, "evidence": ev, "fix": fix,
                           "cis": f"CIS GCP Foundations v3.0.0 {cis}" if cis else None, "source": "rule"})


def load(inv, name):
    p = os.path.join(inv, name)
    if not os.path.exists(p):
        return None, p
    with open(p, encoding="utf-8") as f:
        return json.load(f), p


def g(obj, *keys, default=None):
    """依序嘗試多個 key(camelCase / snake_case)。"""
    for k in keys:
        cur = obj
        ok = True
        for part in k.split("."):
            if isinstance(cur, dict) and part in cur:
                cur = cur[part]
            else:
                ok = False
                break
        if ok:
            return cur
    return default


def meta_items(md):
    return {it.get("key"): it.get("value") for it in ((md or {}).get("items") or []) if isinstance(it, dict)}


def truthy(v):
    return str(v).strip().lower() in ("true", "1", "yes", "on")


def scan(inv, gg_sa=None, now=None):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    o = Out(inv)
    # ---- IAM
    pol, pf = load(inv, "iam-policy.json")
    for i, b in enumerate((pol or {}).get("bindings") or []):
        role = b.get("role")
        for j, m in enumerate(b.get("members") or []):
            path = f"/bindings/{i}/members/{j}"
            if m in PUBLIC:
                o.add("GCP-IAM-001", f"project:{role}", pf, path, f"{m} → {role}")
            if role in ("roles/owner", "roles/editor") and m.startswith("serviceAccount:") and m[15:] != gg_sa:
                o.add("GCP-IAM-002", m, pf, path, role)
            if role == "roles/editor" and m.startswith("user:"):
                o.add("GCP-IAM-003", m, pf, path, role)
            if role in ("roles/iam.serviceAccountUser", "roles/iam.serviceAccountTokenCreator"):
                o.add("GCP-IAM-004", m, pf, path, role)
            if m.startswith("user:") and m.split("@")[-1].lower() in CONSUMER_DOMAINS:
                o.add("GCP-IAM-005", m, pf, path, role)
    # ---- SA keys
    for kf in sorted(glob.glob(os.path.join(inv, "sa-keys", "*.json"))):
        with open(kf, encoding="utf-8") as f:
            keys = json.load(f)
        email = os.path.basename(kf)[:-5]
        for i, k in enumerate(keys or []):
            created = k.get("validAfterTime")
            age = None
            try:
                age = (now - datetime.datetime.fromisoformat(created.replace("Z", "+00:00"))).days
            except Exception:
                pass
            kid = (k.get("name") or "").rsplit("/", 1)[-1][:12]
            if gg_sa and email == gg_sa:
                o.add("GCP-KEY-INFO", f"{email} key {kid}", kf, f"/{i}", f"金鑰年齡 {age} 天")
                continue
            if age is not None and age > 90:
                o.add("GCP-KEY-001", f"{email} key {kid}", kf, f"/{i}/validAfterTime", f"{age} 天", value=created)
            else:
                o.add("GCP-KEY-002", f"{email} key {kid}", kf, f"/{i}", f"{age} 天" if age is not None else "")
    # ---- 網路
    fws, ff = load(inv, "firewalls.json")
    for i, fw in enumerate(fws or []):
        if fw.get("direction", "INGRESS") != "INGRESS" or fw.get("disabled"):
            continue
        srcs = fw.get("sourceRanges") or []
        if not any(s in ("0.0.0.0/0", "::/0") for s in srcs):
            continue
        name = fw.get("name")
        admin, other = [], []
        for a in fw.get("allowed") or []:
            proto = a.get("IPProtocol")
            ports = a.get("ports") or []
            if proto in ("all",) or (proto in ("tcp",) and not ports):
                admin.append(f"{proto}:全部")
                continue
            for p in ports:
                lo, _, hi = str(p).partition("-")
                lo, hi = int(lo), int(hi or lo)
                if proto == "tcp" and (lo <= 22 <= hi or lo <= 3389 <= hi):
                    admin.append(f"{proto}:{p}")
                else:
                    other.append(f"{proto}:{p}")
            if proto not in ("tcp",) and not ports:
                other.append(proto)
        if admin:
            o.add("GCP-NET-001", f"firewall:{name}", ff, f"/{i}/allowed", ", ".join(admin))
        elif other:
            o.add("GCP-NET-002", f"firewall:{name}", ff, f"/{i}/allowed", ", ".join(other))
    nets, nf = load(inv, "networks.json")
    for i, n in enumerate(nets or []):
        if n.get("name") == "default":
            o.add("GCP-NET-003", "network:default", nf, f"/{i}")
    subs, sf = load(inv, "subnets.json")
    for i, s in enumerate(subs or []):
        if s.get("purpose") in ("REGIONAL_MANAGED_PROXY", "GLOBAL_MANAGED_PROXY", "PRIVATE_SERVICE_CONNECT", "INTERNAL_HTTPS_LOAD_BALANCER"):
            continue
        if not g(s, "logConfig.enable", "enableFlowLogs", default=False):
            o.add("GCP-NET-004", f"subnet:{s.get('region', '').rsplit('/', 1)[-1]}/{s.get('name')}", sf, f"/{i}/logConfig")
    # ---- GCS
    bks, bf = load(inv, "buckets.json")
    for i, b in enumerate(bks or []):
        name = b.get("name") or g(b, "storage_url", default="").replace("gs://", "").rstrip("/")
        ubla = g(b, "uniform_bucket_level_access", "iamConfiguration.uniformBucketLevelAccess.enabled", default=None)
        if ubla is False:
            o.add("GCS-UBLA-001", f"gs://{name}", bf, f"/{i}")
        pap = g(b, "public_access_prevention", "iamConfiguration.publicAccessPrevention", default=None)
        if pap is not None and str(pap).lower() != "enforced":
            o.add("GCS-PAP-001", f"gs://{name}", bf, f"/{i}", str(pap))
        ver = g(b, "versioning_enabled", "versioning.enabled", default=None)
        if ver is not True:
            o.add("GCS-VER-001", f"gs://{name}", bf, f"/{i}")
        pol, pff = load(inv, os.path.join("bucket-iam", f"{name}.json"))
        for bi, bb in enumerate((pol or {}).get("bindings") or []):
            for mj, m in enumerate(bb.get("members") or []):
                if m in PUBLIC:
                    o.add("GCS-PUB-001", f"gs://{name}", pff, f"/bindings/{bi}/members/{mj}", f"{m} → {bb.get('role')}")
    # ---- Cloud SQL
    sqls, qf = load(inv, "sql.json")
    for i, s in enumerate(sqls or []):
        name = s.get("name")
        ipc = g(s, "settings.ipConfiguration", default={}) or {}
        for j, n in enumerate(ipc.get("authorizedNetworks") or []):
            if n.get("value") in ("0.0.0.0/0", "::/0"):
                o.add("SQL-PUB-001", f"sql:{name}", qf, f"/{i}/settings/ipConfiguration/authorizedNetworks/{j}")
        if ipc.get("ipv4Enabled"):
            o.add("SQL-IP-001", f"sql:{name}", qf, f"/{i}/settings/ipConfiguration/ipv4Enabled")
        mode = ipc.get("sslMode")
        if mode == "ALLOW_UNENCRYPTED_AND_ENCRYPTED" or (mode is None and not ipc.get("requireSsl")):
            o.add("SQL-SSL-001", f"sql:{name}", qf, f"/{i}/settings/ipConfiguration", str(mode))
        if not g(s, "settings.backupConfiguration.enabled", default=False) and s.get("instanceType") != "READ_REPLICA_INSTANCE":
            o.add("SQL-BAK-001", f"sql:{name}", qf, f"/{i}/settings/backupConfiguration")
    # ---- Compute
    pinfo, pif = load(inv, "project-info.json")
    pmeta = meta_items((pinfo or {}).get("commonInstanceMetadata"))
    proj_oslogin = truthy(pmeta.get("enable-oslogin"))
    vms, vf = load(inv, "instances.json")
    oslogin_missing = []
    for i, vm in enumerate(vms or []):
        name = f"{(vm.get('zone') or '').rsplit('/', 1)[-1]}/{vm.get('name')}"
        if (vm.get("labels") or {}).get("goog-gke-node") is not None or (vm.get("name") or "").startswith("gke-"):
            continue  # GKE 節點由 GKE 規則處理
        for sa in vm.get("serviceAccounts") or []:
            if (sa.get("email") or "").endswith("-compute@developer.gserviceaccount.com"):
                if "https://www.googleapis.com/auth/cloud-platform" in (sa.get("scopes") or []):
                    o.add("GCE-SA-001", f"vm:{name}", vf, f"/{i}/serviceAccounts")
                else:
                    o.add("GCE-SA-002", f"vm:{name}", vf, f"/{i}/serviceAccounts")
        im = meta_items(vm.get("metadata"))
        if truthy(im.get("serial-port-enable", pmeta.get("serial-port-enable"))):
            o.add("GCE-SER-001", f"vm:{name}", vf, f"/{i}/metadata")
        vm_os = im.get("enable-oslogin")
        if not (truthy(vm_os) if vm_os is not None else proj_oslogin):
            oslogin_missing.append(name)
        if not truthy(im.get("block-project-ssh-keys")) and not proj_oslogin:
            o.add("GCE-SSH-001", f"vm:{name}", vf, f"/{i}/metadata")
        if vm.get("canIpForward"):
            o.add("GCE-IPF-001", f"vm:{name}", vf, f"/{i}/canIpForward")
        if not g(vm, "shieldedInstanceConfig.enableSecureBoot", default=False):
            o.add("GCE-SHV-001", f"vm:{name}", vf, f"/{i}/shieldedInstanceConfig")
        for ni, nic in enumerate(vm.get("networkInterfaces") or []):
            if nic.get("accessConfigs"):
                o.add("GCE-IP-001", f"vm:{name}", vf, f"/{i}/networkInterfaces/{ni}/accessConfigs")
    if oslogin_missing:
        o.add("GCE-OSL-001", "project:metadata", pif, "/commonInstanceMetadata/items",
              f"{len(oslogin_missing)} 台 VM 未啟用:{', '.join(oslogin_missing[:5])}")
    # ---- GKE
    cls, cf = load(inv, "clusters.json")
    for i, c in enumerate(cls or []):
        name = f"{c.get('location')}/{c.get('name')}"
        base = f"/{i}"
        man = c.get("masterAuthorizedNetworksConfig") or {}
        pcc = c.get("privateClusterConfig") or {}
        cpe = (c.get("controlPlaneEndpointsConfig") or {}).get("ipEndpointsConfig") or {}
        private_ep = pcc.get("enablePrivateEndpoint") or cpe.get("enablePublicEndpoint") is False
        if not man.get("enabled") and not private_ep:
            o.add("GKE-CP-001", f"gke:{name}", cf, f"{base}/masterAuthorizedNetworksConfig")
        for j, blk in enumerate(man.get("cidrBlocks") or []):
            if blk.get("cidrBlock") in ("0.0.0.0/0", "::/0"):
                o.add("GKE-CP-002", f"gke:{name}", cf, f"{base}/masterAuthorizedNetworksConfig/cidrBlocks/{j}")
        ma = c.get("masterAuth") or {}
        if ma.get("username") or ma.get("password") or ma.get("clientCertificate") or ma.get("clientKey"):
            o.add("GKE-BASIC-001", f"gke:{name}", cf, f"{base}/masterAuth", "（值已遮蔽)")
        if (c.get("legacyAbac") or {}).get("enabled"):
            o.add("GKE-ABAC-001", f"gke:{name}", cf, f"{base}/legacyAbac")
        np_cfg = c.get("networkConfig") or {}
        if not pcc.get("enablePrivateNodes") and not np_cfg.get("defaultEnablePrivateNodes") and not c.get("autopilot", {}).get("enabled") is True:
            o.add("GKE-PRIV-001", f"gke:{name}", cf, f"{base}/privateClusterConfig")
        if not (c.get("workloadIdentityConfig") or {}).get("workloadPool"):
            o.add("GKE-WI-001", f"gke:{name}", cf, f"{base}/workloadIdentityConfig")
        dp2 = np_cfg.get("datapathProvider") == "ADVANCED_DATAPATH"
        if not dp2 and not (c.get("networkPolicy") or {}).get("enabled"):
            o.add("GKE-NP-001", f"gke:{name}", cf, f"{base}/networkPolicy")
        if not (c.get("shieldedNodes") or {}).get("enabled"):
            o.add("GKE-SHN-001", f"gke:{name}", cf, f"{base}/shieldedNodes")
        if not (c.get("releaseChannel") or {}).get("channel") or (c.get("releaseChannel") or {}).get("channel") == "UNSPECIFIED":
            o.add("GKE-REL-001", f"gke:{name}", cf, f"{base}/releaseChannel")
        if c.get("loggingService") == "none" or c.get("monitoringService") == "none":
            o.add("GKE-LOG-001", f"gke:{name}", cf, f"{base}/loggingService")
        # node pools:優先用 nodepools/<cluster>.json,沒有就用叢集內嵌的 nodePools
        nps, npf = load(inv, os.path.join("nodepools", f"{c.get('name')}.json"))
        if nps is None:
            nps, npf, prefix = c.get("nodePools") or [], cf, f"{base}/nodePools"
        else:
            prefix = ""
        for k, npl in enumerate(nps or []):
            npn = f"gke:{name}/{npl.get('name')}"
            pth = f"{prefix}/{k}"
            cfg = npl.get("config") or {}
            if cfg.get("serviceAccount") in (None, "default") or str(cfg.get("serviceAccount")).endswith("-compute@developer.gserviceaccount.com"):
                o.add("GKE-NODE-001", npn, npf, f"{pth}/config/serviceAccount")
            mg = npl.get("management") or {}
            if not mg.get("autoUpgrade"):
                o.add("GKE-NODE-002", npn, npf, f"{pth}/management/autoUpgrade")
            if not mg.get("autoRepair"):
                o.add("GKE-NODE-003", npn, npf, f"{pth}/management/autoRepair")
            if not (cfg.get("shieldedInstanceConfig") or {}).get("enableSecureBoot"):
                o.add("GKE-NODE-004", npn, npf, f"{pth}/config/shieldedInstanceConfig")
            if (cfg.get("workloadMetadataConfig") or {}).get("mode") != "GKE_METADATA":
                o.add("GKE-NODE-005", npn, npf, f"{pth}/config/workloadMetadataConfig")
    return o.items


if __name__ == "__main__":
    args = sys.argv[1:]
    inv = args[0]
    sa = args[args.index("--sa") + 1] if "--sa" in args else None
    now = None
    if "--now" in args:
        now = datetime.datetime.fromisoformat(args[args.index("--now") + 1].replace("Z", "+00:00"))
    json.dump(scan(inv, sa, now), sys.stdout, ensure_ascii=False, indent=1)
