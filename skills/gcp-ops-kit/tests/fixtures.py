"""selftest 的假 GCP 專案資料(全部是虛構值)。"""
P = "demo-proj-123"
GG_SA = f"guardian@{P}.iam.gserviceaccount.com"
APP_SA = f"app@{P}.iam.gserviceaccount.com"
DEF_SA = "123456789-compute@developer.gserviceaccount.com"
OLD = "2026-01-01T00:00:00Z"
FAKE_AKIA = "AKIA" + "ABCDEFGHIJKLMNOP"          # 拆開寫,避免本檔被秘密掃描誤判
FAKE_AIZA = "AIza" + "SyA1234567890abcdefghijklmnopqrstu"
FAKE_CERT = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t" + "QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo="

POLICY = {"bindings": [
    {"role": "roles/owner", "members": ["user:alice@example.com"]},
    {"role": "roles/editor", "members": [f"serviceAccount:{DEF_SA}", f"serviceAccount:{GG_SA}"]},
    {"role": "roles/viewer", "members": ["allUsers"]},
    {"role": "roles/iam.serviceAccountUser", "members": ["user:bob@gmail.com"]},
], "etag": "BwX="}

FIREWALLS = [
    {"name": "allow-ssh", "direction": "INGRESS", "sourceRanges": ["0.0.0.0/0"], "allowed": [{"IPProtocol": "tcp", "ports": ["22"]}], "priority": 1000},
    {"name": "allow-web", "direction": "INGRESS", "sourceRanges": ["0.0.0.0/0"], "allowed": [{"IPProtocol": "tcp", "ports": ["8080"]}], "priority": 1000},
    {"name": "allow-internal", "direction": "INGRESS", "sourceRanges": ["10.0.0.0/8"], "allowed": [{"IPProtocol": "all"}], "priority": 1000},
    {"name": "allow-iap", "direction": "INGRESS", "sourceRanges": ["35.235.240.0/20"], "allowed": [{"IPProtocol": "tcp", "ports": ["22"]}], "priority": 1000},
]

INSTANCES = [{
    "name": "vm1", "zone": "projects/x/zones/asia-east1-b", "canIpForward": True,
    "serviceAccounts": [{"email": DEF_SA, "scopes": ["https://www.googleapis.com/auth/cloud-platform"]}],
    "metadata": {"items": [{"key": "serial-port-enable", "value": "TRUE"},
                           {"key": "startup-script", "value": f"export AWS_KEY={FAKE_AKIA}"}]},
    "networkInterfaces": [{"accessConfigs": [{"natIP": "203.0.113.9"}]}],
    "shieldedInstanceConfig": {"enableSecureBoot": False},
}]

CLUSTER = {
    "name": "prod", "location": "asia-east1", "masterAuthorizedNetworksConfig": {},
    "masterAuth": {"clientCertificate": FAKE_CERT, "clusterCaCertificate": "Q0E="},
    "privateClusterConfig": {}, "networkPolicy": {}, "shieldedNodes": {"enabled": True},
    "releaseChannel": {"channel": "REGULAR"}, "loggingService": "logging.googleapis.com/kubernetes",
    "monitoringService": "monitoring.googleapis.com/kubernetes", "endpoint": "34.80.0.10",
}
NODEPOOLS = [{"name": "default-pool", "locations": ["asia-east1-a", "asia-east1-b"],
              "config": {"serviceAccount": "default", "shieldedInstanceConfig": {"enableSecureBoot": False}},
              "management": {"autoUpgrade": True, "autoRepair": True},
              "autoscaling": {"enabled": False}}]

DEPLOY = {"apiVersion": "apps/v1", "kind": "Deployment",
          "metadata": {"name": "web", "namespace": "shop", "resourceVersion": "100",
                       "annotations": {"kubectl.kubernetes.io/last-applied-configuration": "{\"x\":1}"}},
          "spec": {"replicas": 2, "template": {"metadata": {}, "spec": {"containers": [{
              "name": "web", "image": "nginx:1.27.3",
              "env": [{"name": "DB_PASSWORD", "value": "hunter2-very-secret"}, {"name": "LOG_LEVEL", "value": "info"}]}]}}}}


def k8s_items(kind):
    return {
        "namespaces": [{"kind": "Namespace", "metadata": {"name": "shop"}}, {"kind": "Namespace", "metadata": {"name": "kube-system"}}],
        "deployments": [DEPLOY],
        "configmaps": [{"kind": "ConfigMap", "metadata": {"name": "cfg", "namespace": "shop"}, "data": {"api_key": FAKE_AIZA}}],
    }.get(kind, [])


def review_fixtures():
    fx = [
        {"tool": "gcloud", "re": f"^projects describe {P} ", "out": {"projectId": P}},
        {"tool": "gcloud", "re": f"^projects get-iam-policy {P} ", "out": POLICY},
        {"tool": "gcloud", "re": "^iam service-accounts list ", "out": [{"email": GG_SA}, {"email": APP_SA}]},
        {"tool": "gcloud", "re": f"^iam service-accounts keys list --iam-account={GG_SA} ", "out": [{"name": "k/abc", "validAfterTime": OLD}]},
        {"tool": "gcloud", "re": f"^iam service-accounts keys list --iam-account={APP_SA} ", "out": [{"name": "k/def", "validAfterTime": OLD}]},
        {"tool": "gcloud", "re": "^services list ", "out": []},
        {"tool": "gcloud", "re": "^compute project-info describe ", "out": {"commonInstanceMetadata": {"items": [
            {"key": "enable-oslogin", "value": "FALSE"}, {"key": "team-token", "value": FAKE_AKIA},
            {"key": "startup-script", "value": "export DB_PASSWORD=hunter2-project-wide"}]}}},
        {"tool": "gcloud", "re": "^compute networks list ", "out": [{"name": "default"}]},
        {"tool": "gcloud", "re": "^compute networks subnets list ", "out": [{"name": "default", "region": "r/asia-east1"}]},
        {"tool": "gcloud", "re": "^compute firewall-rules list ", "out": FIREWALLS},
        {"tool": "gcloud", "re": "^compute addresses list ", "out": []},
        {"tool": "gcloud", "re": "^compute routers list ", "out": []},
        {"tool": "gcloud", "re": "^compute instances list ", "out": INSTANCES},
        {"tool": "gcloud", "re": "^storage buckets list ", "out": [{"name": "public-assets", "uniform_bucket_level_access": False,
                                                                    "public_access_prevention": "inherited", "versioning_enabled": False}]},
        {"tool": "gcloud", "re": "^storage buckets get-iam-policy gs://public-assets ", "when": {"bucket_public": None},
         "out": {"bindings": [{"role": "roles/storage.objectViewer", "members": ["allUsers"]}]}},
        {"tool": "gcloud", "re": "^storage buckets get-iam-policy gs://public-assets ", "when": {"bucket_public": False},
         "out": {"bindings": []}},
        {"tool": "gcloud", "re": "^sql instances list ", "out": [{"name": "db1", "settings": {"ipConfiguration": {
            "ipv4Enabled": True, "authorizedNetworks": [{"value": "0.0.0.0/0"}], "sslMode": "ALLOW_UNENCRYPTED_AND_ENCRYPTED"},
            "backupConfiguration": {"enabled": False}}}]},
        {"tool": "gcloud", "re": "^container clusters list ", "out": [CLUSTER]},
        {"tool": "gcloud", "re": "^container node-pools list --cluster=prod ", "out": NODEPOOLS},
    ]
    for kind in ["namespaces", "pods", "deployments", "daemonsets", "statefulsets", "replicasets", "jobs", "cronjobs",
                 "services", "ingresses", "networkpolicies", "serviceaccounts", "roles", "rolebindings",
                 "clusterroles", "clusterrolebindings", "configmaps"]:
        fx.append({"tool": "kubectl", "re": f" get {kind} -A -o json", "out": {"items": k8s_items(kind)}})
    fx.append({"tool": "kubectl", "re": " get secrets -A -o=go-template=", "out": "shop\tdb\tOpaque\tpassword,\n"})
    return fx


# 審查應得的規則(多重集合)
EXPECTED_REVIEW = sorted([
    "GCP-IAM-001", "GCP-IAM-002", "GCP-IAM-004", "GCP-IAM-005", "GCP-KEY-INFO", "GCP-KEY-001",
    "GCP-NET-001", "GCP-NET-002", "GCP-NET-003", "GCP-NET-004",
    "GCS-PUB-001", "GCS-UBLA-001", "GCS-PAP-001", "GCS-VER-001",
    "SQL-PUB-001", "SQL-IP-001", "SQL-SSL-001", "SQL-BAK-001",
    "GCE-SA-001", "GCE-SER-001", "GCE-SSH-001", "GCE-IPF-001", "GCE-SHV-001", "GCE-IP-001", "GCE-OSL-001",
    "GKE-CP-001", "GKE-BASIC-001", "GKE-PRIV-001", "GKE-WI-001", "GKE-NP-001",
    "GKE-NODE-001", "GKE-NODE-004", "GKE-NODE-005",
    "K8S-SA-001", "K8S-ROOT-001", "K8S-PE-001", "K8S-ROFS-001", "K8S-RES-001", "K8S-PROBE-001", "K8S-SEC-002",
    "K8S-NP-001", "K8S-PSA-001",
])
