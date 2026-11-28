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
                v = re.sub(r"\s+#.*$", "", v).strip().strip('"').strip("'")  # 去掉行內註解
                cfg[k.strip()] = os.path.expanduser(v)
    elif require:
        raise Blocked(f"找不到設定檔 {path}(內容:GG_SA_KEY_FILE=<金鑰絕對路徑>,或 GG_AUTH=user + GG_ACCOUNT=<你的帳號>;權限 600)")
    cfg.setdefault("GG_REPORT_DIR", os.path.expanduser("~/gcp-guardian-reports"))
    cfg["GG_REPORT_DIR"] = os.path.abspath(cfg["GG_REPORT_DIR"])
    if any(c.isspace() for c in cfg["GG_REPORT_DIR"]):
        raise Blocked("GG_REPORT_DIR 不可含空白(白名單以空白分隔參數);請在設定檔改成沒有空白的路徑")
    cfg["GG_AUTH"] = cfg.get("GG_AUTH", "sa").lower()
    if cfg["GG_AUTH"] not in ("sa", "user"):
        raise Blocked("GG_AUTH 只能是 sa(專用 SA 金鑰)或 user(使用者自己的 gcloud 登入)")
    if require and cfg["GG_AUTH"] == "user":
        acct = cfg.get("GG_ACCOUNT", "").strip().lower()  # IAM 成員一律小寫
        cfg["GG_ACCOUNT"] = acct
        if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[^@\s]+", acct):
            raise Blocked("GG_AUTH=user 時設定檔要有 GG_ACCOUNT=<你在 gcloud 登入的帳號 email>")
        cfg["GG_SA"] = acct  # 「自己的身分」:禁止動自己的 IAM 綁定等規則照樣套用
        cfg["GG_PRINCIPAL"] = ("serviceAccount:" if acct.endswith("gserviceaccount.com") else "user:") + acct
        return cfg
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
        cfg["GG_PRINCIPAL"] = "serviceAccount:" + cfg["GG_SA"]
    return cfg


PROJECT_RE = re.compile(r"^[a-z][a-z0-9-]{4,28}[a-z0-9]$")


def check_project(p):
    if p in ("gcloud", "kubeconfig", "_yaml"):
        raise Blocked(f"專案 ID {p} 與 kit 保留名稱相同,無法使用")
    if not p or not PROJECT_RE.match(p):
        raise Blocked(f"專案 ID 格式不對:{p!r}")
    return p


# ---------------------------------------------------------------- run 目錄 / 專案鎖

def install_signal_handlers():
    """SIGTERM / SIGHUP / SIGINT 轉成 SystemExit,讓 with / finally 清掉憑證快取、寫出紀錄。"""
    import signal

    def _h(signum, frame):
        raise SystemExit(128 + signum)
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(sig, _h)


STALE_CRED_SECONDS = 6 * 3600


def clean_stale_creds(cfg):
    """上次被強制結束(SIGKILL)留下的 gcloud/、kubeconfig:超過 6 小時就刪掉。"""
    rd = cfg["GG_REPORT_DIR"]
    if not os.path.isdir(rd):
        return
    now = time.time()
    import fcntl
    for proj in os.listdir(rd):
        pd = os.path.join(rd, proj)
        if not os.path.isdir(pd):
            continue
        lp = os.path.join(pd, ".lock")
        if os.path.exists(lp):  # 計畫 / 變更進行中(鎖被持有)就不碰這個專案
            try:
                fd = os.open(lp, os.O_RDWR)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    fcntl.flock(fd, fcntl.LOCK_UN)
                finally:
                    os.close(fd)
            except OSError:
                continue
        for run in os.listdir(pd):
            p = os.path.join(pd, run, "gcloud")
            try:
                if not os.path.lexists(p):
                    continue
                owner = read_json(os.path.join(p, "owner.json"), {}) or {}
                dead = owner.get("pid") and not _pid_alive(owner.get("pid"))
                if dead or now - os.lstat(p).st_mtime > STALE_CRED_SECONDS:
                    shutil.rmtree(p, ignore_errors=True)  # 程序已不在(例如被 SIGKILL)就立刻清
            except OSError:
                pass
    for x in os.listdir(rd):
        if x.startswith(".check-"):
            p = os.path.join(rd, x)
            try:
                if now - os.lstat(p).st_mtime > STALE_CRED_SECONDS:
                    shutil.rmtree(p, ignore_errors=True)
            except OSError:
                pass


def new_run(cfg, project, mode):
    install_signal_handlers()
    clean_stale_creds(cfg)
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
        "kit": KIT, "sa": cfg.get("GG_SA"), "auth": cfg.get("GG_AUTH", "sa"),
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
    got = False
    for _ in range(10):  # 短暫重試:其他程序的殘留清理可能正在探測這把鎖
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            got = True
            break
        except OSError:
            time.sleep(0.2)
    if not got:
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
        self.kube = os.path.join(run, "gcloud", "kubeconfig")  # 放在 gcloud/ 裡:旁邊的外掛快取也一起受保護、一起刪
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
        write_json(os.path.join(self.gdir, "owner.json"), {"pid": os.getpid(), "started": now_iso()})
        os.makedirs(self.home, 0o700, exist_ok=True)
        os.makedirs(os.path.dirname(self.kube), 0o700, exist_ok=True)
        open(self.kube, "a").close()
        os.chmod(self.kube, 0o600)
        try:
            if self.cfg.get("GG_AUTH") == "user":
                self._refresh_user_token()
            else:
                r = self._exec(["gcloud", "auth", "activate-service-account", "<key>",
                                f"--project={self.project}", "--quiet"], check_mode="read")
                if r.returncode != 0:
                    raise Blocked("SA 啟用失敗:" + _short(r.stderr))
        except BaseException:
            self.__exit__(None, None, None)
            raise
        return self

    # 取 token 時保證至少剩 15 分鐘;每 5 分鐘換新,任何時刻至少剩約 10 分鐘
    TOKEN_MAX_AGE = 5 * 60

    def _refresh_user_token(self):
        """GG_AUTH=user:用使用者自己的 gcloud 登入取短效 access token,寫進 run 內的隔離目錄。
        不複製使用者的憑證檔;token 只放 <run>/gcloud/token(權限 600,結束時刪除),gcloud / kubectl 外掛都讀這個檔。"""
        acct = self.cfg["GG_ACCOUNT"].strip()
        user_env = {k: v for k, v in os.environ.items() if not k.startswith("CLOUDSDK_AUTH_")}
        user_env["CLOUDSDK_CORE_DISABLE_PROMPTS"] = "1"  # 要重新驗證時直接失敗,不等輸入
        try:
            # config-helper --min-expiry:保證拿到的 token 至少還有 15 分鐘(不會拿到快過期的快取 token)
            r = subprocess.run(["gcloud", "config", "config-helper", "--format=json", "--min-expiry=15m", f"--account={acct}", "--quiet"],
                               env=user_env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
        except FileNotFoundError:
            raise Blocked("找不到 gcloud")
        except subprocess.TimeoutExpired:
            raise Blocked("取 access token 逾時")
        try:
            tok = (json.loads(r.stdout or "{}").get("credential") or {}).get("access_token") or ""
        except ValueError:
            tok = ""
        tok = tok.strip()
        if r.returncode != 0 or not tok or any(c.isspace() for c in tok):
            raise Blocked(f"無法用帳號 {acct} 取得 access token(請使用者自己在終端機執行 gcloud auth login {acct}):"
                          + _short(scrub_text(r.stderr or "", self.cfg)))
        path = os.path.join(self.gdir, "token")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(tok)
        self.env["CLOUDSDK_AUTH_ACCESS_TOKEN_FILE"] = path
        # GKE 驗證外掛會另外快取 token:換新時一併清掉,讓 kubectl 下次重新取
        for root, _, files in os.walk(self.gdir):
            for fn in files:
                if fn == "gke_gcloud_auth_plugin_cache":
                    try:
                        os.remove(os.path.join(root, fn))
                    except OSError:
                        pass
        self.env["CLOUDSDK_CORE_ACCOUNT"] = acct
        self._token_at = time.time()
        append_log(self.run, "commands", {"mode": "auth", "argv": ["gcloud", "config", "config-helper", "--min-expiry=15m", "--account=<GG_ACCOUNT>"],
                                          "rc": r.returncode, "note": "使用者自己的 gcloud 登入;token 只寫 run 內隔離目錄"})

    def ensure_fresh(self):
        """帳號模式:token 太舊就換新(在送出變更前呼叫;失敗丟 Blocked,代表指令還沒送出)。"""
        if self.cfg.get("GG_AUTH") == "user" and time.time() - getattr(self, "_token_at", 0) > self.TOKEN_MAX_AGE:
            self._refresh_user_token()

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
            # --async / --format=json 是 kit 執行時自己加的(計畫裡不准寫),檢查形狀時先拿掉
            shape = ggchange.classify([a for a in argv if a not in ("--async", "--format=json")], self.cfg, shape_only=True)
            if shape["blocked_reason"]:
                raise Denied("變更指令不被允許:" + shape["blocked_reason"])
        else:
            raise Denied("未知模式")
        self.ensure_fresh()  # 帳號模式:每個指令前確認 token 夠新
        real = [("--key-file=" + self.cfg["GG_SA_KEY_FILE"]) if a == "<key>" else a for a in argv]
        if check_mode == "change":
            append_log(self.run, "commands", {"mode": check_mode, "argv": argv, "rc": None, "state": "started"})
        for hb in (self.gdir, self.kube):  # 心跳:讓其他 run 的殘留清理知道這些憑證還在用
            try:
                os.utime(hb)
            except OSError:
                pass
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

SECRET_NAME_RE = re.compile(r"(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential|(^|[_-])auth([_-]?(key|token|pass(word)?|secret|header))?$|dsn|conn(ection)?[_-]?str)", re.I)
KEEP_METADATA_KEYS = {
    "serial-port-enable", "enable-oslogin", "block-project-ssh-keys", "enable-oslogin-2fa",
    "enable-guest-attributes", "disable-legacy-endpoints",
}
with open(os.path.join(RULES_DIR, "secret_patterns.json"), encoding="utf-8") as _f:
    SECRET_VALUE_PATTERNS = [re.compile(p) for p in json.load(_f)["patterns"]]


def redact_value(v):
    s = v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)
    return f"<redacted len={len(s)}>"  # 不附雜湊:避免離線猜密碼


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


ENV_ASSIGN_RE = re.compile(r"(\b[A-Za-z_][A-Za-z0-9_]*(?:pass(?:word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential|auth|dsn)[A-Za-z0-9_]*)=(\"[^\"]*\"|'[^']*'|\S+)", re.I)
URL_CRED_RE = re.compile(r"([A-Za-z][A-Za-z0-9+.-]*://[^/\s:@]+:)([^/\s@]+)(@)")


def _redact_inline(x):
    """字串內嵌的 NAME=value(名稱像秘密)與 URL 帳密。"""
    x = ENV_ASSIGN_RE.sub(lambda m: m.group(1) + "=" + redact_value(m.group(2)), x)
    x = URL_CRED_RE.sub(lambda m: m.group(1) + redact_value(m.group(2)) + m.group(3), x)
    return x


def _redact_argv(items):
    out, hide_next = [], False
    for x in items:
        x = x if hide_next else _redact_inline(x)
        if hide_next:
            out.append(x if x.startswith("<redacted") else redact_value(x))
            hide_next = False
            continue
        m = ARG_SECRET_RE.match(x)
        if m and "<redacted" in m.group(2):
            out.append(x)  # _redact_inline 已遮過
        elif m:
            out.append(m.group(1) + redact_value(m.group(2)))
        elif re.fullmatch(r"--?[A-Za-z0-9_.-]*(pass(word|wd)?|secret|token|api[_-]?key|private[_-]?key|credential)", x, re.I):
            out.append(x)
            hide_next = True
        elif any(pt.search(x) for pt in SECRET_VALUE_PATTERNS) or (len(x) >= 24 and entropy(x) >= 4.5 and " " not in x):
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
    if pointer == "":
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
