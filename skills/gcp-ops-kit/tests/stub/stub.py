"""假 gcloud / kubectl / gke-gcloud-auth-plugin(selftest 用)。

$GG_STUB_DIR/fixtures.json:[{"tool": "gcloud", "re": "<regex,search 於 argv 以空白串接>", "out": <JSON 或字串>,
                              "rc": 0, "err": "", "when": {狀態}, "set": {狀態}}]
$GG_STUB_DIR/state.json:目前狀態;$GG_STUB_LOG:每次呼叫記一行 JSON(tool、argv、CLOUDSDK_CONFIG、KUBECONFIG)。
get-credentials 會在 $KUBECONFIG 寫入 context gke_<p>_<l>_<c>,server 取 state.endpoint(預設 https://10.0.0.1)。
"""
import json
import os
import re
import sys

tool, argv = sys.argv[1], sys.argv[2:]
d = os.environ.get("GG_STUB_DIR", "")
text = " ".join(argv)
with open(os.environ["GG_STUB_LOG"], "a", encoding="utf-8") as f:
    f.write(json.dumps({"tool": tool, "argv": argv, "CLOUDSDK_CONFIG": os.environ.get("CLOUDSDK_CONFIG"),
                        "KUBECONFIG": os.environ.get("KUBECONFIG"), "HOME": os.environ.get("HOME"),
                        "TOKEN_FILE": os.environ.get("CLOUDSDK_AUTH_ACCESS_TOKEN_FILE")}, ensure_ascii=False) + "\n")
if tool == "gke-gcloud-auth-plugin":
    sys.exit(0)
sp = os.path.join(d, "state.json")
state = json.load(open(sp)) if os.path.exists(sp) else {}
if tool == "gcloud" and argv[:2] == ["auth", "print-access-token"]:
    if state.get("user_not_logged_in"):
        sys.stderr.write("ERROR: (gcloud.auth.print-access-token) There was a problem refreshing your current auth tokens\n")
        sys.exit(1)
    print("ya29." + "x" * 40)  # 假 token(符合秘密樣式,用來確認不外洩)
    sys.exit(0)
if tool == "gcloud" and argv[:2] == ["auth", "activate-service-account"]:
    if state.get("activate_fail"):
        sys.stderr.write("ERROR: (gcloud.auth.activate-service-account) key disabled\n")
        sys.exit(1)
    sys.exit(0)
if tool == "gcloud" and argv[:3] == ["container", "clusters", "get-credentials"]:
    name = argv[3]
    loc = [a.split("=", 1)[1] for a in argv if a.startswith("--location=")][0]
    proj = [a.split("=", 1)[1] for a in argv if a.startswith("--project=")][0]
    ctx = f"gke_{proj}_{loc}_{name}"
    kc = os.environ["KUBECONFIG"]
    server = state.get("endpoint", "https://10.0.0.1")
    with open(kc, "a", encoding="utf-8") as f:
        f.write(f"---\napiVersion: v1\nkind: Config\nclusters:\n- name: {ctx}\n  cluster:\n    server: {server}\n"
                f"contexts:\n- name: {ctx}\n  context:\n    cluster: {ctx}\n    user: {ctx}\ncurrent-context: {ctx}\n")
    # 多次 get-credentials 時只保留最後一份(簡化)
    content = open(kc).read().split("---\n")[-1]
    open(kc, "w").write(content)
    sys.exit(0)
fixtures = json.load(open(os.path.join(d, "fixtures.json")))
for fx in fixtures:
    if fx.get("tool", tool) != tool or not re.search(fx["re"], text):
        continue
    if any(state.get(k) != v for k, v in (fx.get("when") or {}).items()):
        continue
    if fx.get("set"):
        state.update(fx["set"])
        json.dump(state, open(sp, "w"))
    if fx.get("sleep"):
        import time
        time.sleep(fx["sleep"])
    out = fx.get("out", "")
    sys.stdout.write(out if isinstance(out, str) else json.dumps(out))
    sys.stderr.write(fx.get("err", ""))
    sys.exit(fx.get("rc", 0))
sys.stderr.write(f"stub: no fixture for {tool} {text}\n")
sys.exit(1)
