"""測試用假 GitHub API。用法:python3 -I mock_api.py <port 檔>"""
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "ghs_testtoken"
PAT = "ghp_testpat"

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

    def auth(self):
        a = self.headers.get("Authorization", "")
        return a[7:] if a.startswith("Bearer ") else ""

    def is_jwt(self):
        return self.auth().count(".") == 2

    def do_GET(self):
        p = self.path
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
        if p == "/repos/o/r/pulls/7" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": "a" * 40}})
        if p == "/repos/o/r/pulls/8" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"state": "open", "mergeable": False, "mergeable_state": "dirty", "head": {"sha": "a" * 40}})
        if p == "/repos/o/r/pulls/9" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "unstable", "head": {"sha": "a" * 40}})
        if p == "/repos/o/r/pulls/10" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"state": "closed", "mergeable": None, "mergeable_state": "unknown", "head": {"sha": "a" * 40}})
        if p == "/repos/o/r" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"default_branch": "develop"})
        self.send(401, {"message": "bad request " + p})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/app/installations/42/access_tokens" and self.is_jwt():
            if body != {"repositories": ["r"]}:
                return self.send(422, {"message": "bad scope"})
            return self.send(201, {"token": TOKEN})
        if self.path == "/repos/o/r/pulls" and self.auth() in (TOKEN, PAT):
            return self.send(201, {"html_url": "https://github.com/o/r/pull/7", "echo": body})
        self.send(401, {"message": "bad request " + self.path})

    def do_PUT(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        if self.path == "/repos/o/r/pulls/7/merge" and self.auth() in (TOKEN, PAT):
            if body != {"sha": "a" * 40, "merge_method": "merge"}:
                return self.send(422, {"message": "bad merge body"})
            return self.send(200, {"merged": True, "sha": "b" * 40})
        self.send(401, {"message": "bad request " + self.path})

srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
