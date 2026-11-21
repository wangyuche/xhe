"""測試用假 GitHub API。用法:python3 -I mock_api.py <port 檔>"""
import json, sys, time
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
        a40, d40, e40 = "a" * 40, "d" * 40, "e" * 40
        if p == f"/repos/o/r/commits/{a40}/check-runs?per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}]})
        if p == f"/repos/o/r/commits/{a40}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/commits/{d40}/check-runs?per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "in_progress", "conclusion": None}]})
        if p == f"/repos/o/r/commits/{d40}/status" or p == f"/repos/o/r/commits/{e40}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/commits/{e40}/check-runs?per_page=100":
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/contents/.github/workflows?ref={e40}":
            return self.send(200, [{"name": "ci.yml"}])
        s17 = "4" * 40
        if p == "/repos/o/r/pulls/17":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s17}})
        if p == f"/repos/o/r/commits/{s17}/check-runs?per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "lint", "status": "completed", "conclusion": "skipped", "app": {"slug": "github-actions"}}]})
        if p == f"/repos/o/r/commits/{s17}/check-suites?per_page=100":
            return self.send(200, {"total_count": 2, "check_suites": [
                {"id": 171, "app": {"slug": "github-actions"}, "status": "completed", "conclusion": "skipped", "latest_check_runs_count": 1},
                {"id": 172, "app": {"slug": "github-actions"}, "status": "queued", "conclusion": None, "latest_check_runs_count": 0}]})
        s18 = "5" * 40
        if p == "/repos/o/r/pulls/18":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s18}})
        if p == f"/repos/o/r/commits/{s18}/check-runs?per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}}]})
        s19 = "6" * 40
        if p == "/repos/o/r/pulls/19":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s19}})
        if p == f"/repos/o/r/commits/{s19}/check-runs?per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "lint-app", "status": "completed", "conclusion": "success", "app": {"slug": "some-linter"}}]})
        if p == f"/repos/o/r/commits/{s19}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s19}":
            return self.send(200, [{"name": "ci.yml"}])
        s21 = "8" * 40
        if p == "/repos/o/r/pulls/21":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s21}})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s21}":
            return self.send(200, [{"name": "deploy.yml"}])
        if p == f"/repos/o/r/commits/{s21}/check-runs?per_page=100":
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/commits/{s21}/status":
            return self.send(200, {"state": "failure", "total_count": 1})
        s22 = "9" * 40
        if p == "/repos/o/r/pulls/22":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s22}})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s22}":
            return self.send(200, [{"name": "ci.yml"}])
        if p == f"/repos/o/r/commits/{s22}/check-runs?per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}}]})
        if p == f"/repos/o/r/commits/{s22}/check-suites?per_page=100":
            return self.send(200, {"total_count": 2, "check_suites": [
                {"id": 221, "app": {"slug": "github-actions"}, "status": "completed", "conclusion": "cancelled", "latest_check_runs_count": 1},
                {"id": 222, "app": {"slug": "github-actions"}, "status": "completed", "conclusion": "success", "latest_check_runs_count": 1}]})
        if p == f"/repos/o/r/commits/{s22}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        s20 = "7" * 40
        if p == "/repos/o/r/pulls/20":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s20}})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s20}":
            return self.send(200, [{"name": "README.md"}])
        if p == f"/repos/o/r/commits/{s20}/check-runs?per_page=100":
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/commits/{s20}/status":
            return self.send(200, {"state": "success", "total_count": 1})
        if p == f"/repos/o/r/commits/{s18}/check-suites?per_page=100":
            return self.send(200, {"total_count": 2, "check_suites": [
                {"id": 181, "app": {"slug": "github-actions"}, "status": "completed", "conclusion": "success", "latest_check_runs_count": 1},
                {"id": 182, "app": {"slug": "github-actions"}, "status": "queued", "conclusion": None, "latest_check_runs_count": 0}]})
        if p == f"/repos/o/r/commits/{s18}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s18}":
            return self.send(200, [{"name": "ci.yml"}, {"name": "docs.yml"}])
        if p == f"/repos/o/r/commits/{s17}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if "/check-suites?per_page=100" in p and self.auth() in (TOKEN, PAT):
            return self.send(200, {"total_count": 0, "check_suites": [
                {"id": 99, "app": {"slug": "some-app"}, "status": "queued", "conclusion": None, "latest_check_runs_count": 0}]})
        f40 = "f" * 40
        if p == f"/repos/o/r/commits/{f40}/check-runs?per_page=100":
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/commits/{f40}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/contents/.github/workflows?ref={f40}":
            return self.send(502, {"message": "Bad Gateway"})
        # 14:只有外部 status(無 workflow 目錄)且失敗;15:無 workflow、無任何 CI;
        # 16:有 workflow,外部 status 已 success 但 Actions check run 還沒登記
        s14, s15, s16 = "1" * 40, "2" * 40, "3" * 40
        for n, sh in ((14, s14), (15, s15), (16, s16)):
            if p == f"/repos/o/r/pulls/{n}":
                return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": sh}})
        if p in (f"/repos/o/r/commits/{s14}/check-runs?per_page=100", f"/repos/o/r/commits/{s15}/check-runs?per_page=100",
                 f"/repos/o/r/commits/{s16}/check-runs?per_page=100"):
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/commits/{s14}/status":
            return self.send(200, {"state": "failure", "total_count": 1})
        if p == f"/repos/o/r/commits/{s15}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/commits/{s16}/status":
            return self.send(200, {"state": "success", "total_count": 1})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s16}":
            return self.send(200, [{"name": "ci.yml"}])
        if p.startswith("/repos/o/r/contents/.github/workflows?ref=") and p.endswith(s17):
            return self.send(200, [{"name": "ci.yml"}, {"name": "test.yml"}])
        if p.startswith("/repos/o/r/contents/.github/workflows?ref=") and not p.endswith((e40, f40, s16)):
            return self.send(404, {"message": "Not Found"})
        if p == "/repos/o/r/pulls/13":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": f40}})
        if p == "/repos/o/moved":
            return self.send(301, {"message": "Moved Permanently"})
        if p == "/repos/o/r/pulls/11":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": d40}})
        if p == "/repos/o/r/pulls/12":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": e40}})
        if p == "/repos/o/nodef" and self.auth() in (TOKEN, PAT):
            return self.send(200, {})
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
        if self.path == "/repos/o/r/pulls/22/merge" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"merged": True, "sha": "c" * 40})
        if self.path == "/repos/o/r/pulls/20/merge" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"merged": True, "sha": "c" * 40})
        if self.path == "/repos/o/r/pulls/18/merge" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"merged": True, "sha": "c" * 40})
        if self.path == "/repos/o/r/pulls/12/merge" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"merged": True, "sha": "c" * 40})
        if self.path == "/repos/o/r/pulls/7/merge" and self.auth() in (TOKEN, PAT):
            if body != {"sha": "a" * 40, "merge_method": "merge"}:
                return self.send(422, {"message": "bad merge body"})
            return self.send(200, {"merged": True, "sha": "b" * 40})
        self.send(401, {"message": "bad request " + self.path})

srv = HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write(str(srv.server_port))
srv.serve_forever()
