"""測試用假 GitHub API。用法:python3 -I mock_api.py <port 檔>"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "ghs_testtoken"
PAT = "ghp_testpat"

# merge 情境:PR 號碼 → (head SHA, mergeable_state, state)
A = "a" * 40
PRS = {
    7: (A, "clean", "open"),          # 沒有 CI → 可以合併
    8: (A, "dirty", "open"),          # 衝突
    9: (A, "unstable", "open"),       # GitHub 說有檢查未過
    10: (A, "unknown", "closed"),     # 已關閉
    11: ("1" * 40, "clean", "open"),  # 有空的 check suite
    12: ("2" * 40, "clean", "open"),  # 有 check run
    13: ("3" * 40, "clean", "open"),  # 有 commit status
    14: ("4" * 40, "clean", "open"),  # 有 workflow run
    15: ("5" * 40, "clean", "open"),  # .github/workflows 有檔案
    16: ("6" * 40, "clean", "open"),  # workflows 查詢 502
    17: ("7" * 40, "clean", "open"),  # status 第 3 次查詢才出現(等待期間)
    18: ("8" * 40, "clean", "open"),  # status 只在合併前最後一次查詢出現
}
# 每個 SHA 的 CI 計數:suites, runs, statuses, workflow runs
CI = {"1" * 40: (1, 0, 0, 0), "2" * 40: (0, 1, 0, 0), "3" * 40: (0, 0, 1, 0), "4" * 40: (0, 0, 0, 1)}
WORKFLOW_FILES = {"5" * 40: [{"name": "ci.yml"}]}
CALLS = {}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)
        return True

    def auth(self):
        a = self.headers.get("Authorization", "")
        return a[7:] if a.startswith("Bearer ") else ""

    def is_jwt(self):
        return self.auth().count(".") == 2

    def authed(self):
        return self.auth() in (TOKEN, PAT)

    def ci_get(self, p):
        """/repos/o/r/commits/<sha>/... 與 actions/runs、contents/.github/workflows;沒處理到回傳 None"""
        if p.startswith("/repos/o/r/contents/.github/workflows?ref="):
            sha = p.split("ref=")[1]
            if sha == "6" * 40:
                return self.send(502, {"message": "Bad Gateway"})
            if sha in WORKFLOW_FILES:
                return self.send(200, WORKFLOW_FILES[sha])
            return self.send(404, {"message": "Not Found"})
        if p.startswith("/repos/o/r/actions/runs?head_sha="):
            sha = p.split("head_sha=")[1].split("&")[0]
            return self.send(200, {"total_count": CI.get(sha, (0, 0, 0, 0))[3], "workflow_runs": []})
        if p.startswith("/repos/o/r/commits/"):
            sha, rest = p[len("/repos/o/r/commits/"):].split("/", 1)
            suites, runs, statuses, _ = CI.get(sha, (0, 0, 0, 0))
            if rest.startswith("check-suites"):
                return self.send(200, {"total_count": suites, "check_suites": []})
            if rest.startswith("check-runs"):
                return self.send(200, {"total_count": runs, "check_runs": []})
            if rest == "status":
                CALLS[sha] = CALLS.get(sha, 0) + 1
                if sha == "7" * 40 and CALLS[sha] >= 3:
                    statuses = 1
                if sha == "8" * 40 and CALLS[sha] >= 5:   # 等待 4 次之後、合併前那次
                    statuses = 1
                return self.send(200, {"state": "pending", "total_count": statuses})
        return None

    def do_GET(self):
        p = self.path
        if self.authed() and p.startswith(
                ("/repos/o/r/contents/.github/workflows", "/repos/o/r/actions/runs", "/repos/o/r/commits/")):
            if self.ci_get(p) is None:
                self.send(404, {"message": "Not Found"})
            return
        if p == "/repos/o/r/installation" and self.is_jwt():
            return self.send(200, {"id": 42})
        if p == "/repos/o/missing/installation":
            return self.send(404, {"message": "Not Found"})
        if p == "/app" and self.is_jwt():
            return self.send(200, {"slug": "xhe-bot"})
        if p == "/users/xhe-bot%5Bbot%5D" and self.auth() == TOKEN:
            return self.send(200, {"id": 12345})
        if p == "/user" and self.auth() == PAT:
            return self.send(200, {"login": "xhe-bot", "id": 777})
        if p.startswith("/repos/o/r/pulls?state=open&head=o:") and self.authed():
            if p.split("head=o:")[1].split("&")[0] == "feat/existing":
                return self.send(200, [{"html_url": "https://github.com/o/r/pull/5"}])
            return self.send(200, [])
        if p.startswith("/repos/o/r/pulls/") and self.authed():
            n = int(p.rsplit("/", 1)[1])
            if n in PRS:
                sha, st, state = PRS[n]
                return self.send(200, {"state": state, "mergeable_state": st, "head": {"sha": sha}})
        if p == "/repos/o/nodef" and self.authed():
            return self.send(200, {})
        if p == "/repos/o/moved":
            return self.send(301, {"message": "Moved Permanently"})
        if p == "/repos/o/r" and self.authed():
            return self.send(200, {"default_branch": "develop"})
        self.send(401, {"message": "bad request " + p})

    def body(self):
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")

    def do_POST(self):
        body = self.body()
        if self.path == "/app/installations/42/access_tokens" and self.is_jwt():
            if body != {"repositories": ["r"]}:
                return self.send(422, {"message": "bad scope"})
            return self.send(201, {"token": TOKEN})
        if self.path == "/repos/o/r/pulls" and self.authed():
            return self.send(201, {"html_url": "https://github.com/o/r/pull/7", "echo": body})
        self.send(401, {"message": "bad request " + self.path})

    def do_PUT(self):
        body = self.body()
        if self.path == "/repos/o/r/pulls/7/merge" and self.authed():
            if body != {"sha": A, "merge_method": "merge"}:
                return self.send(422, {"message": "bad merge body"})
            return self.send(200, {"merged": True, "sha": "b" * 40})
        self.send(401, {"message": "bad request " + self.path})


srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
