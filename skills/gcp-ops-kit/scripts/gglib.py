"""gcp-ops-kit 共用函式庫(不可單獨執行)。

- 設定:~/.config/gcp-guardian/config(GG_CONFIG 可覆寫,selftest 用)
- run 目錄:<GG_REPORT_DIR>/<專案>/<時間>-<模式>/,權限 700
- 隔離:每個 run 自己的 CLOUDSDK_CONFIG / KUBECONFIG,結束時刪除
- 包裝:_gcloud / _kubectl 只在本模組內使用,強制 --project / --context,並依模式比對白名單
- 遮蔽、秘密掃描、專案鎖、JSON pointer
"""
import datetime
import hashlib
import json
import math
import os
import re
import shlex
import shutil
import stat
import subprocess
import sys
import time

KIT = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
RULES_DIR = os.path.join(KIT, "rules")

EXIT_OK, EXIT_FAIL, EXIT_USAGE, EXIT_BLOCKED, EXIT_DENIED = 0, 1, 2, 3, 4


class Blocked(Exception):
    """事前檢查不過 → 回報 BLOCKED。"""


class Denied(Exception):
    """指令不在白名單 / 命中拒絕樣式。"""


# ---------------------------------------------------------------- 設定

def config_path():
    return os.environ.get("GG_CONFIG") or os.path.expanduser("~/.config/gcp-guardian/config")


def _mode_ok(path):
    st = os.stat(path)
    return stat.S_IMODE(st.st_mode) & 0o077 == 0


def load_config(require=True):
    """讀 KEY=value 設定。require=True 時缺檔 / 權限不對 / 缺金鑰 → Blocked。"""
    path = config_path()
    cfg = {}
    if os.path.exists(path):
        if require and not _mode_ok(path):
            raise Blocked(f"設定檔權限要是 600:chmod 600 {path}")
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = v.strip().strip('"').strip("'")
                cfg[k.strip()] = os.path.expanduser(v)
    elif require:
        raise Blocked(f"找不到設定檔 {path}(內容:GG_SA_KEY_FILE=<金鑰絕對路徑>,權限 600)")
    cfg.setdefault("GG_REPORT_DIR", os.path.expanduser("~/gcp-guardian-reports"))
    if any(c.isspace() for c in cfg["GG_REPORT_DIR"]):
        raise Blocked("GG_REPORT_DIR 不可含空白(白名單以空白分隔參數);請在設定檔改成沒有空白的路徑")
    if require:
        key = cfg.get("GG_SA_KEY_FILE")
        if not key or not os.path.isfile(key):
            raise Blocked("設定檔缺 GG_SA_KEY_FILE,或金鑰檔不存在")
        if not _mode_ok(key):
            raise Blocked(f"金鑰檔權限要是 600:chmod 600 {key}")
        try:
            with open(key, encoding="utf-8") as f:
                cfg["GG_SA"] = json.load(f)["client_email"]
        except Exception:
            raise Blocked("金鑰檔不是有效的 SA JSON(缺 client_email)")
    return cfg


PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")


def check_project(p):
    if not p or not PROJECT_RE.match(p):
        raise Blocked(f"專案 ID 格式不對:{p!r}")
    return p


# ---------------------------------------------------------------- run 目錄 / 專案鎖

def new_run(cfg, project, mode):
    base = os.path.join(cfg["GG_REPORT_DIR"], project)
    if not os.path.exists(cfg["GG_REPORT_DIR"]):
        os.makedirs(cfg["GG_REPORT_DIR"], mode=0o700)  # 只有 kit 自己建立時才設 700
    os.makedirs(base, mode=0o700, exist_ok=True)
    os.chmod(base, 0o700)
    ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    for i in range(100):
        run = os.path.join(base, f"{ts}-{mode}" + (f"-{i}" if i else ""))
        try:
            os.mkdir(run, 0o700)
            break
        except FileExistsError:
            continue
    else:
        raise Blocked("同一秒內建立的 run 目錄太多,請稍後再試")
    write_json(os.path.join(run, "meta.json"), {
        "project": project, "mode": mode, "started": now_iso(),
        "kit": KIT, "sa": cfg.get("GG_SA"),
    })
    return run


_LOCKS = {}


def acquire_lock(cfg, project, mode, run):
    """專案鎖:fcntl.flock(程序結束或當掉時由系統自動釋放,沒有「過期」判斷)。"""
    import fcntl
    base = os.path.join(cfg["GG_REPORT_DIR"], project)
    os.makedirs(base, mode=0o700, exist_ok=True)
    path = os.path.join(base, ".lock")
    fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        try:
            info = json.loads(os.pread(fd, 4096, 0).decode("utf-8") or "{}")
        except Exception:
            info = {}
        os.close(fd)
        raise Blocked(f"專案 {project} 的鎖被佔用({info.get('mode', '?')} run={info.get('run', '?')});"
                      "同專案的計畫 / 變更不可並行")
    os.ftruncate(fd, 0)
    os.pwrite(fd, json.dumps({"pid": os.getpid(), "mode": mode, "run": run, "created": time.time()}).encode(), 0)
    _LOCKS[(base, run)] = fd
    return path


def release_lock(cfg, project, run=None):
    base = os.path.join(cfg["GG_REPORT_DIR"], project)
    for key in [k for k in _LOCKS if k[0] == base and (run is None or k[1] == run)]:
        fd = _LOCKS.pop(key)
        try:
            os.close(fd)  # 關檔即釋放 flock
        except OSError:
            pass


def _pid_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------- 白名單

_PLACEHOLDERS = {
    "{P}": r"[a-z][a-z0-9-]{4,28}[a-z0-9]",
    "{L}": r"[a-z0-9-]+",
    "{N}": r"[A-Za-z0-9][A-Za-z0-9._-]{0,252}",
    "{CTX}": r"gke_[a-z0-9-]+_[a-z0-9-]+_[A-Za-z0-9._-]+",
    "{SA}": r"[a-z0-9-]+@[a-z0-9.-]+\.(?:iam\.gserviceaccount\.com|gserviceaccount\.com)",
    "{B}": r"gs://[a-z0-9][a-z0-9._-]{1,221}",
    "{KIND}": r"(?:namespaces|pods|deployments|daemonsets|statefulsets|replicasets|jobs|cronjobs|services|ingresses|networkpolicies|serviceaccounts|roles|rolebindings|clusterroles|clusterrolebindings|configmaps|nodes|horizontalpodautoscalers|poddisruptionbudgets)",
    "{RUNFILE}": r"/[^ ]+/(?:manifests|patches)/C[0-9]+\.(?:yaml|json)",
    "{KEY}": r"<key>",
    "{LABEL}": r"cloud\.google\.com/gke-nodepool=[A-Za-z0-9._-]+",
}

SECRET_TMPL = ('{{range .items}}{{.metadata.namespace}}{{"\\t"}}{{.metadata.name}}{{"\\t"}}'
               '{{.type}}{{"\\t"}}{{range $k, $v := .data}}{{$k}},{{end}}{{"\\n"}}{{end}}')


def _load_patterns(name):
    pats = []
    with open(os.path.join(RULES_DIR, name), encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if name.startswith("deny"):
                pats.append(re.compile(line))
                continue
            rx = re.escape(line)
            # re.escape 會把 {P} 轉成 \{P\};換回占位符
            for ph, sub in _PLACEHOLDERS.items():
                rx = rx.replace(re.escape(ph), sub)
            rx = rx.replace(re.escape("{SECRET_TMPL}"), re.escape(SECRET_TMPL))
            rx = rx.replace(re.escape("{ANY}"), r"[^ ]+")
            pats.append(re.compile("^" + rx + "$"))
    return pats


def argv_text(argv):
    return " ".join(argv)


def check_read(argv, mode):
    """mode: read(審查)/ dryrun(計畫、變更前檢查)。命中拒絕樣式或不在白名單 → Denied。"""
    text = argv_text(argv)
    for rx in _load_patterns("deny_read.txt"):
        if rx.search(text):
            raise Denied(f"命中拒絕樣式 {rx.pattern!r}:{text}")
    files = ["allow_read.txt"] + (["allow_dryrun.txt"] if mode in ("dryrun", "change") else [])
    for fn in files:
        for rx in _load_patterns(fn):
            if rx.match(text):
                return True
    raise Denied(f"不在 {'/'.join(files)} 白名單:{text}")


# ---------------------------------------------------------------- 隔離執行

class Session:
    """一個 run 的隔離 gcloud / kubectl 環境。用 with 包住,結束刪除憑證快取。"""

    def __init__(self, cfg, run, project, mode):
        self.cfg, self.run, self.project, self.mode = cfg, run, project, mode
        self.gdir = os.path.join(run, "gcloud")
        self.kube = os.path.join(run, "kubeconfig")
        self.home = os.path.join(run, "gcloud", "home")  # kubectl / auth plugin 的快取都留在 run 內,結束一起刪
        self.env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "HOME": self.home,
            "LANG": "C.UTF-8",
            "CLOUDSDK_CONFIG": self.gdir,
            "KUBECONFIG": self.kube,
            "CLOUDSDK_CORE_DISABLE_PROMPTS": "1",
            "USE_GKE_GCLOUD_AUTH_PLUGIN": "True",
        }
        for k in ("GG_STUB_DIR", "GG_STUB_LOG", "TMPDIR", "CLOUDSDK_PYTHON"):
            if os.environ.get(k):
                self.env[k] = os.environ[k]

    def __enter__(self):
        os.makedirs(self.gdir, 0o700, exist_ok=True)
        os.makedirs(self.home, 0o700, exist_ok=True)
        open(self.kube, "a").close()
        os.chmod(self.kube, 0o600)
        try:
            r = self._exec(["gcloud", "auth", "activate-service-account", "<key>",
                            f"--project={self.project}", "--quiet"], check_mode="read")
            if r.returncode != 0:
                raise Blocked("SA 啟用失敗:" + _short(r.stderr))
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    def __exit__(self, *a):
        shutil.rmtree(self.gdir, ignore_errors=True)
        try:
            os.remove(self.kube)
        except FileNotFoundError:
            pass
        return False

    # 內部:真正執行。argv 裡的 <key> 在檢查與記錄時保留占位,執行時才換成 --key-file。
    def _exec(self, argv, check_mode, timeout=180, input_text=None):
        tool = argv[0]
        if tool == "gcloud" and not any(a.startswith("--project=") for a in argv):
            raise Denied("gcloud 缺 --project:" + argv_text(argv))
        if tool == "kubectl" and not (len(argv) > 1 and argv[1].startswith("--context=")):
            raise Denied("kubectl 缺 --context(要放在第一個參數):" + argv_text(argv))
        if tool not in ("gcloud", "kubectl"):
            raise Denied("只允許 gcloud / kubectl:" + argv_text(argv))
        if check_mode in ("read", "dryrun"):
            check_read(argv, check_mode)
        elif check_mode == "change":
            import ggchange  # 第二道防線:只檢查形狀(允許清單、共同禁止、旗標);完整判定在 change.py
            shape = ggchange.classify(argv, self.cfg, shape_only=True)
            if shape["blocked_reason"]:
                raise Denied("變更指令不被允許:" + shape["blocked_reason"])
        else:
            raise Denied("未知模式")
        real = [("--key-file=" + self.cfg["GG_SA_KEY_FILE"]) if a == "<key>" else a for a in argv]
        t0 = time.time()
        try:
            r = subprocess.run(real, env=self.env, capture_output=True, text=True,
                               timeout=timeout, input=input_text)
        except FileNotFoundError:
            r = subprocess.CompletedProcess(real, 127, "", f"{tool}: command not found")
        except subprocess.TimeoutExpired:
            r = subprocess.CompletedProcess(real, 124, "", f"timeout {timeout}s")
        append_log(self.run, "commands", {
            "mode": check_mode, "argv": argv, "rc": r.returncode,
            "seconds": round(time.time() - t0, 2),
        })
        r.stdout = r.stdout or ""
        r.stderr = scrub_text(r.stderr or "", self.cfg)
        return r

    def gcloud(self, args, mode="read", **kw):
        return self._exec(["gcloud"] + args, mode, **kw)

    def kubectl(self, context, args, mode="read", **kw):
        return self._exec(["kubectl", f"--context={context}"] + args, mode, **kw)

    def get_credentials(self, cluster, location):
        r = self.gcloud(["container", "clusters", "get-credentials", cluster,
                         f"--location={location}", f"--project={self.project}", "--quiet"])
        return r, f"gke_{self.project}_{location}_{cluster}"

    def context_endpoint(self, context):
        """回傳 kubeconfig 中該 context 的叢集 server(從檔案讀,不呼叫 kubectl)。"""
        try:
            data = subprocess.run(["ruby", os.path.join(KIT, "scripts", "yaml2json.rb"), self.kube],
                                  capture_output=True, text=True, timeout=30).stdout
            docs = json.loads(data or "[]")
        except Exception:
            return None
        if not docs:
            return None
        kc = docs[0]["obj"]
        cl = None
        for c in kc.get("contexts") or []:
            if c.get("name") == context:
                cl = (c.get("context") or {}).get("cluster")
        for c in kc.get("clusters") or []:
            if c.get("name") == cl:
                return (c.get("cluster") or {}).get("server")
        return None


def _short(s, n=600):
    s = (s or "").strip()
    return s if len(s) <= n else s[:n] + "…"


# ---------------------------------------------------------------- 遮蔽

SECRET_NAME_RE = re.compile(r"(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential|auth|dsn|conn(ection)?[_-]?str)", re.I)
KEEP_METADATA_KEYS = {
    "serial-port-enable", "enable-oslogin", "block-project-ssh-keys", "enable-oslogin-2fa",
    "enable-guest-attributes", "disable-legacy-endpoints",
}
with open(os.path.join(RULES_DIR, "secret_patterns.json"), encoding="utf-8") as _f:
    SECRET_VALUE_PATTERNS = [re.compile(p) for p in json.load(_f)["patterns"]]


def redact_value(v):
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    h = hashlib.sha256(s.encode("utf-8")).hexdigest()[:8]
    return f"<redacted len={len(s)} sha256={h}>"


def entropy(s):
    if not s:
        return 0.0
    freq = {}
    for ch in s:
        freq[ch] = freq.get(ch, 0) + 1
    return -sum(c / len(s) * math.log2(c / len(s)) for c in freq.values())


def looks_secret(name, value):
    if not isinstance(value, str) or value == "":
        return False
    if any(p.search(value) for p in SECRET_VALUE_PATTERNS):
        return True
    if name and SECRET_NAME_RE.search(name) and len(value) >= 6:
        return True
    if len(value) >= 24 and entropy(value) >= 4.0 and re.fullmatch(r"[A-Za-z0-9+/=_.\-]+", value):
        return True
    return False


def redact(obj, path=""):
    """遞迴遮蔽。回傳新物件,不改原物件。"""
    if isinstance(obj, list):
        return [redact(x, f"{path}/{i}") for i, x in enumerate(obj)]
    if not isinstance(obj, dict):
        if isinstance(obj, str) and any(p.search(obj) for p in SECRET_VALUE_PATTERNS):
            return redact_value(obj)
        return obj
    kind = obj.get("kind")
    out = {}
    for k, v in obj.items():
        p = f"{path}/{k}"
        if kind == "Secret" and k in ("data", "stringData") and isinstance(v, dict):
            out[k] = {kk: redact_value(vv) for kk, vv in v.items()}
        elif kind == "ConfigMap" and k in ("data", "binaryData") and isinstance(v, dict):
            out[k] = {kk: redact_value(vv) for kk, vv in v.items()}
        elif k == "masterAuth" and isinstance(v, dict):
            out[k] = {kk: (redact_value(vv) if vv not in (None, "", {}) else vv) for kk, vv in v.items()}
        elif k in ("command", "args") and isinstance(v, list) and all(isinstance(x, str) for x in v):
            out[k] = _redact_argv(v)
        elif k == "metadata" and isinstance(v, dict) and p.endswith(("/config/metadata", "/nodeConfig/metadata")):
            # GKE node pool config.metadata(dict):保留布林設定,其他值遮蔽
            out[k] = {kk: (vv if kk in KEEP_METADATA_KEYS else redact_value(vv)) for kk, vv in v.items()}
        elif k == "env" and isinstance(v, list):
            out[k] = [_redact_env(e) for e in v]
        elif k in ("metadata", "commonInstanceMetadata") and isinstance(v, dict) and isinstance(v.get("items"), list):
            # GCE instance / commonInstanceMetadata:{items:[{key,value}]}
            nv = dict(v)
            nv["items"] = [_redact_meta_item(it) for it in v["items"]]
            out[k] = nv
        elif k == "annotations" and isinstance(v, dict):
            out[k] = {kk: (redact_value(vv) if kk == "kubectl.kubernetes.io/last-applied-configuration"
                           or looks_secret(kk, vv) else vv) for kk, vv in v.items()}
        else:
            out[k] = redact(v, p)
    return out


ARG_SECRET_RE = re.compile(r"^(--?[A-Za-z0-9_.-]*(?:pass(?:word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential|auth)[A-Za-z0-9_.-]*[=:])(.+)$", re.I)


def _redact_argv(items):
    out, hide_next = [], False
    for x in items:
        if hide_next:
            out.append(redact_value(x))
            hide_next = False
            continue
        m = ARG_SECRET_RE.match(x)
        if m:
            out.append(m.group(1) + redact_value(m.group(2)))
        elif re.fullmatch(r"--?[A-Za-z0-9_.-]*(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential)", x, re.I):
            out.append(x)
            hide_next = True
        elif any(pt.search(x) for pt in SECRET_VALUE_PATTERNS):
            out.append(redact_value(x))
        else:
            out.append(x)
    return out


def _redact_env(e):
    if not isinstance(e, dict):
        return e
    e = dict(e)
    if "value" in e:
        e["looks_secret"] = looks_secret(e.get("name", ""), e["value"])
        e["value"] = redact_value(e["value"])
    return e


def _redact_meta_item(it):
    if not isinstance(it, dict):
        return it
    it = dict(it)
    if it.get("key") in KEEP_METADATA_KEYS:
        return it
    if "value" in it:
        it["value"] = redact_value(it["value"])
    return it


def scrub_text(s, cfg=None):
    for p in SECRET_VALUE_PATTERNS:
        s = p.sub("<redacted>", s)
    if cfg and cfg.get("GG_SA_KEY_FILE"):
        s = s.replace(cfg["GG_SA_KEY_FILE"], "<key>")
    return s


def scan_secrets(text):
    """回傳命中的樣式清單(--check 用)。"""
    hits = [p.pattern for p in SECRET_VALUE_PATTERNS if p.search(text)]
    return hits


# ---------------------------------------------------------------- JSON / 工具

def now_iso():
    return datetime.datetime.now().astimezone().isoformat(timespec="seconds")


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), 0o700, exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2, sort_keys=False)
        f.write("\n")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def append_log(run, name, rec):
    rec = dict(rec)
    rec["ts"] = now_iso()
    p = os.path.join(run, "inventory" if name == "commands" else "", f"{name}.log")
    os.makedirs(os.path.dirname(p), 0o700, exist_ok=True)
    with open(p, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, ensure_ascii=False) + "\n")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def ptr_get(obj, pointer, default=None):
    """JSON pointer(/a/0/b,~1 = /)。"""
    if pointer in ("", "/"):
        return obj
    cur = obj
    for part in pointer.lstrip("/").split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        if isinstance(cur, list):
            if not part.isdigit():
                return default
            try:
                cur = cur[int(part)]
            except IndexError:
                return default
        elif isinstance(cur, dict):
            if part not in cur:
                return default
            cur = cur[part]
        else:
            return default
    return cur


def die(msg, code=EXIT_FAIL):
    print(msg, file=sys.stderr)
    sys.exit(code)
