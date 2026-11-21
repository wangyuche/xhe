"""測試用假 GitLab API。用法:python3 -I mock_api.py <port 檔> <請求紀錄檔> [情境檔]

只聽 127.0.0.1。路徑可帶或不帶 /api/v4 前綴。專案:grp/proj(id 42,預設分支 develop)。

情境控制:
  - token(PRIVATE-TOKEN 標頭)決定 /personal_access_tokens/self 的回應:
      glpat-full     scopes [api, write_repository]
      glpat-readapi  scopes [read_api, read_repository](這次真實踩過:開 MR 403 insufficient_scope)
      glpat-noself   404(某些 token 類型不支援此端點)
  - 情境檔(JSON,每次請求重讀)可覆寫:{"scopes": [...]} 或 {"self_status": 500}
  - POST /__reset 重設 MR 輪詢計數(不需 token)
  - 每個請求以「METHOD 路徑」一行寫進請求紀錄檔(POST/PUT 另附 body),供測試檢查有沒有重複建立

MR 情境(iid → 說明),head SHA 預設 a*40:
  1  mergeable、沒有 CI → 可合併
  2  description 內含未跳脫的 \\x01(bug a:jq 直接解析會失敗)
  3  detailed_merge_status 先 unchecked 兩次、checking 一次才 mergeable(bug b;要帶 with_merge_status_recheck=true 才會前進)
  4  has_conflicts
  5  head(c*40)有 .gitlab-ci.yml
  6  head(d*40)有 pipeline
  7  目標分支 withci 有 .gitlab-ci.yml
  8  已關閉
  9  head(e*40)有 commit status
  10 查詢 head(f*40)的 .gitlab-ci.yml 回 500(必須拒絕,不能當成沒有 CI)
"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlsplit, parse_qs, unquote

PORT_FILE, LOG_FILE = sys.argv[1], sys.argv[2]
SCENARIO_FILE = sys.argv[3] if len(sys.argv) > 3 else None
TOKENS = {
    "glpat-full": ["api", "write_repository"],
    "glpat-readapi": ["read_api", "read_repository"],
    "glpat-noself": None,
}
A, C, D, E, F = "a" * 40, "c" * 40, "d" * 40, "e" * 40, "f" * 40
WEB = "https://gitlab.example.test/grp/proj"
PROJ = "/projects/grp%2Fproj"


def mr(iid, sha=A, target="develop", state="opened", status="mergeable", conflicts=False, desc="ok"):
    return {"iid": iid, "sha": sha, "state": state, "source_branch": f"feat/{iid}", "target_branch": target,
            "has_conflicts": conflicts, "detailed_merge_status": status, "merge_status": "can_be_merged",
            "description": desc, "web_url": f"{WEB}/-/merge_requests/{iid}"}


MRS = {
    1: mr(1),
    2: mr(2, desc="含控制字元\u0001的說明"),
    3: mr(3),
    4: mr(4, conflicts=True, status="conflict"),
    5: mr(5, sha=C),
    6: mr(6, sha=D),
    7: mr(7, target="withci"),
    8: mr(8, state="closed", status="not_open"),
    9: mr(9, sha=E),
    10: mr(10, sha=F),
}
CI_FILE_REFS = {C, "withci"}
PIPELINES = {D: [{"id": 1, "status": "running"}]}
STATUSES = {E: [{"name": "jenkins", "status": "pending"}]}
RECHECK = {}  # iid → 帶 recheck 的 GET 次數


def scenario():
    if not SCENARIO_FILE:
        return {}
    try:
        with open(SCENARIO_FILE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def raw(self, code, b):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def send(self, code, obj, control_chars=False):
        b = json.dumps(obj, ensure_ascii=True)
        if control_chars:  # GitLab 實際回傳過:字串內的控制字元沒有跳脫
            b = b.replace("\\u0001", "\x01")
        self.raw(code, b.encode())

    def log(self, extra=""):
        try:  # body 壓成一行,方便測試用 grep + jq 檢查
            extra = json.dumps(json.loads(extra), ensure_ascii=False) if extra else ""
        except ValueError:
            extra = extra.replace("\n", "\\n")
        with open(LOG_FILE, "a") as f:
            f.write(f"{self.command} {self.path}{(' ' + extra) if extra else ''}\n")

    def route(self):
        u = urlsplit(self.path)
        p = u.path
        if p.startswith("/api/v4/"):
            p = p[len("/api/v4"):]
        return p, parse_qs(u.query)

    def token(self):
        t = self.headers.get("PRIVATE-TOKEN", "")
        return t if t in TOKENS else None

    def body(self):
        n = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(n).decode() if n else ""

    def do_GET(self):
        self.log()
        p, q = self.route()
        tok = self.token()
        if tok is None:
            return self.send(401, {"message": "401 Unauthorized"})
        if p == "/user":
            return self.send(200, {"username": "botuser", "name": "Bot User", "email": "bot@example.test",
                                   "commit_email": "_private"})
        if p == "/personal_access_tokens/self":
            sc = scenario()
            if "self_status" in sc:
                return self.send(sc["self_status"], {"message": "scenario"})
            scopes = sc.get("scopes", TOKENS[tok])
            if scopes is None:
                return self.send(404, {"message": "404 Not Found"})
            return self.send(200, {"id": 1, "name": "xhe-bot", "scopes": scopes, "active": True,
                                   "revoked": False, "expires_at": "2027-01-31"})
        if p in (PROJ, "/projects/42"):
            proj = {"id": 42, "path_with_namespace": "grp/proj", "default_branch": "develop",
                    "web_url": WEB, "permissions": {"project_access": {"access_level": 30}}}
            if "ci_config_path" in scenario():
                proj["ci_config_path"] = scenario()["ci_config_path"]
            return self.send(200, proj)
        if not p.startswith(PROJ + "/"):
            return self.send(404, {"message": "404 Not Found " + p})
        rest = p[len(PROJ) + 1:]
        if rest == "protected_branches":
            return self.send(200, [{"name": "main"}, {"name": "develop"}])
        if rest == "repository/files/.gitlab-ci.yml":
            ref = q.get("ref", [""])[0]
            if ref in CI_FILE_REFS:
                return self.send(200, {"file_name": ".gitlab-ci.yml"})
            if ref == F:
                return self.send(500, {"message": "500 Internal Server Error"})
            return self.send(404, {"message": "404 File Not Found"})
        if rest == "merge_requests":
            # 既有 MR:feat/existing → develop;查別的 target_branch 時不算
            if q.get("state") == ["opened"] and q.get("source_branch") == ["feat/existing"] and q.get("target_branch", ["develop"]) == ["develop"]:
                return self.send(200, [{"iid": 5, "web_url": f"{WEB}/-/merge_requests/5"}])
            return self.send(200, [])
        if rest.startswith("merge_requests/"):
            iid = int(rest.split("/")[1])
            if iid not in MRS:
                return self.send(404, {"message": "404 Not found"})
            m = dict(MRS[iid])
            if iid == 3:
                n = RECHECK.get(iid, 0)
                if q.get("with_merge_status_recheck") == ["true"]:
                    RECHECK[iid] = n + 1
                m["detailed_merge_status"] = "unchecked" if n < 2 else "checking" if n < 3 else "mergeable"
            return self.send(200, m, control_chars=(iid == 2))
        if rest == "pipelines":
            return self.send(200, PIPELINES.get(q.get("sha", [""])[0], []))
        if rest.startswith("repository/commits/") and rest.endswith("/statuses"):
            sha = rest.split("/")[2]
            return self.send(200, STATUSES.get(sha, []))
        self.send(404, {"message": "404 Not Found " + p})

    def do_POST(self):
        b = self.body()
        self.log(b)
        p, _ = self.route()
        if p == "/__reset":
            RECHECK.clear()
            return self.send(200, {})
        if self.token() is None:
            return self.send(401, {"message": "401 Unauthorized"})
        if p == PROJ + "/merge_requests":
            if (scenario().get("scopes") or TOKENS[self.token()] or []).count("api") == 0:
                return self.send(403, {"error": "insufficient_scope"})
            d = json.loads(b or "{}")
            if not d.get("source_branch") or not d.get("title"):
                return self.send(400, {"message": "missing"})
            return self.send(201, {"iid": 12, "web_url": f"{WEB}/-/merge_requests/12"})
        self.send(404, {"message": "404 Not Found " + p})

    def do_PUT(self):
        b = self.body()
        self.log(b)
        p, _ = self.route()
        if self.token() is None:
            return self.send(401, {"message": "401 Unauthorized"})
        if p.startswith(PROJ + "/merge_requests/") and p.endswith("/merge"):
            iid = int(p.split("/")[-2])
            m = MRS.get(iid)
            d = json.loads(b or "{}")
            if not m or d.get("sha") != m["sha"]:
                return self.send(409, {"message": "SHA does not match HEAD of source branch"})
            return self.send(200, {"state": "merged", "web_url": m["web_url"], "merge_commit_sha": "b" * 40})
        self.send(404, {"message": "404 Not Found " + p})


srv = HTTPServer(("127.0.0.1", 0), H)
with open(PORT_FILE, "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
