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
        # GitHub Actions workflow runs(依 head SHA)
        def wr(wid, name, status, concl, csid, created, event="pull_request"):
            return {"workflow_id": wid, "name": name, "status": status, "conclusion": concl, "event": event,
                    "check_suite_id": csid, "created_at": created, "run_attempt": 1}
        def cr(name, status, concl, csid, app="github-actions"):
            return {"name": name, "status": status, "conclusion": concl, "app": {"slug": app}, "check_suite": {"id": csid}}
        WRUNS = {
            "4" * 40: [wr(1, "lint", "completed", "skipped", 171, "2026-01-01T00:00:00Z"),
                       wr(2, "test", "queued", None, 172, "2026-01-01T00:00:01Z")],
            "5" * 40: [wr(1, "ci", "completed", "success", 181, "2026-01-01T00:00:00Z"),
                       wr(2, "docs", "queued", None, 182, "2026-01-01T00:00:01Z")],
            "9" * 40: [wr(1, "ci", "completed", "cancelled", 221, "2026-01-01T00:00:00Z"),
                       wr(1, "ci", "completed", "success", 222, "2026-01-01T00:00:05Z")],
            "0" * 40: [wr(1, "lint", "completed", "success", 231, "2026-01-01T00:00:00Z"),
                       wr(2, "test", "completed", "cancelled", 232, "2026-01-01T00:00:01Z")],
            "a1" * 20: [wr(1, "ci", "completed", "failure", 241, "2026-01-01T00:00:00Z", "pull_request"),
                        wr(1, "ci", "completed", "success", 242, "2026-01-01T00:00:05Z", "push")],
            "a2" * 20: [wr(1, "ci", "completed", "success", 251, "2026-01-01T00:00:00Z")],
            "b1" * 20: [dict(wr(1, "ci", "completed", "success", 101, "2026-01-01T00:00:00Z"), run_attempt=2)],
            "b2" * 20: [wr(1, "ci", "completed", "failure", 111, "2026-01-01T00:00:00Z"),
                        wr(1, "ci", "completed", "skipped", 112, "2026-01-01T00:00:05Z")],
        }
        CRUNS = {
            "4" * 40: [cr("lint", "completed", "skipped", 171)],
            "5" * 40: [cr("ci", "completed", "success", 181)],
            "9" * 40: [cr("ci", "completed", "cancelled", 221), cr("ci", "completed", "success", 222)],
            "0" * 40: [cr("lint", "completed", "success", 231)],
            "a1" * 20: [cr("ci", "completed", "failure", 241), cr("ci", "completed", "success", 242)],
            "a2" * 20: [cr("ci", "completed", "success", 251), cr("Test Report", "completed", "failure", 251)],
            "a3" * 20: [cr("ci", "completed", "success", 261, "some-ci"), cr("lint", "queued", None, 555, "foo")],
            "b1" * 20: [cr("ci", "completed", "cancelled", 100), cr("ci", "completed", "success", 101)],
            "b2" * 20: [cr("ci", "completed", "failure", 111), cr("ci", "completed", "skipped", 112)],
        }
        for sha, runs in CRUNS.items():
            if p == f"/repos/o/r/commits/{sha}/check-runs?filter=all&per_page=100":
                return self.send(200, {"total_count": len(runs), "check_runs": runs})
        b3 = "b3" * 20
        if p == "/repos/o/r/pulls/27":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": b3}})
        if p == f"/repos/o/r/commits/{b3}/status":
            H.status_calls = getattr(H, "status_calls", 0) + 1
            # check_ci 等待期間(前 4 次)是 success,合併前最後一次變成 failure
            return self.send(200, {"state": "success" if H.status_calls <= 4 else "failure", "total_count": 1})
        for n, sha, st in ((24, "a1" * 20, "clean"), (25, "a2" * 20, "clean"), (26, "a3" * 20, "unstable"),
                           (28, "b1" * 20, "clean"), (29, "b2" * 20, "clean")):
            if p == f"/repos/o/r/pulls/{n}":
                return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": st, "head": {"sha": sha}})
            if p == f"/repos/o/r/commits/{sha}/status":
                return self.send(200, {"state": "pending", "total_count": 0})
            if p == f"/repos/o/r/contents/.github/workflows?ref={sha}" and n != 26:
                return self.send(200, [{"name": "ci.yml"}])
        a3 = "a3" * 20
        if p == f"/repos/o/r/commits/{a3}/check-suites?per_page=100":
            return self.send(200, {"total_count": 2, "check_suites": [
                {"id": 261, "app": {"slug": "some-ci"}, "status": "completed", "conclusion": "success", "latest_check_runs_count": 1},
                {"id": 555, "app": {"slug": "foo"}, "status": "queued", "conclusion": None, "latest_check_runs_count": 1}]})
        if p.startswith("/repos/o/r/actions/runs?head_sha=") and self.auth() in (TOKEN, PAT):
            sha = p.split("head_sha=")[1].split("&")[0]
            runs = WRUNS.get(sha, [])
            return self.send(200, {"total_count": len(runs), "workflow_runs": runs})
        s23 = "0" * 40
        if p == "/repos/o/r/pulls/23":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s23}})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s23}":
            return self.send(200, [{"name": "lint.yml"}, {"name": "test.yml"}])
        if p == f"/repos/o/r/commits/{s23}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "lint", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}}]})
        if p == f"/repos/o/r/commits/{s23}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
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
        if p == f"/repos/o/r/commits/{a40}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success"}]})
        if p == f"/repos/o/r/commits/{a40}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/commits/{d40}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "in_progress", "conclusion": None}]})
        if p == f"/repos/o/r/commits/{d40}/status" or p == f"/repos/o/r/commits/{e40}/status":
            return self.send(200, {"state": "pending", "total_count": 0})
        if p == f"/repos/o/r/commits/{e40}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/contents/.github/workflows?ref={e40}":
            return self.send(200, [{"name": "ci.yml"}])
        s17 = "4" * 40
        if p == "/repos/o/r/pulls/17":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s17}})
        if p == f"/repos/o/r/commits/{s17}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "lint", "status": "completed", "conclusion": "skipped", "app": {"slug": "github-actions"}}]})
        if p == f"/repos/o/r/commits/{s17}/check-suites?per_page=100":
            return self.send(200, {"total_count": 2, "check_suites": [
                {"id": 171, "app": {"slug": "github-actions"}, "status": "completed", "conclusion": "skipped", "latest_check_runs_count": 1},
                {"id": 172, "app": {"slug": "github-actions"}, "status": "queued", "conclusion": None, "latest_check_runs_count": 0}]})
        s18 = "5" * 40
        if p == "/repos/o/r/pulls/18":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s18}})
        if p == f"/repos/o/r/commits/{s18}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 1, "check_runs": [{"name": "ci", "status": "completed", "conclusion": "success", "app": {"slug": "github-actions"}}]})
        s19 = "6" * 40
        if p == "/repos/o/r/pulls/19":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s19}})
        if p == f"/repos/o/r/commits/{s19}/check-runs?filter=all&per_page=100":
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
        if p == f"/repos/o/r/commits/{s21}/check-runs?filter=all&per_page=100":
            return self.send(200, {"total_count": 0, "check_runs": []})
        if p == f"/repos/o/r/commits/{s21}/status":
            return self.send(200, {"state": "failure", "total_count": 1})
        s22 = "9" * 40
        if p == "/repos/o/r/pulls/22":
            return self.send(200, {"state": "open", "mergeable": True, "mergeable_state": "clean", "head": {"sha": s22}})
        if p == f"/repos/o/r/contents/.github/workflows?ref={s22}":
            return self.send(200, [{"name": "ci.yml"}])
        if p == f"/repos/o/r/commits/{s22}/check-runs?filter=all&per_page=100":
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
        if p == f"/repos/o/r/commits/{s20}/check-runs?filter=all&per_page=100":
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
        if p == f"/repos/o/r/commits/{f40}/check-runs?filter=all&per_page=100":
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
        if p in (f"/repos/o/r/commits/{s14}/check-runs?filter=all&per_page=100", f"/repos/o/r/commits/{s15}/check-runs?filter=all&per_page=100",
                 f"/repos/o/r/commits/{s16}/check-runs?filter=all&per_page=100"):
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
        if "/check-runs?filter=all&per_page=100" in p and self.auth() in (TOKEN, PAT):
            return self.send(200, {"total_count": 0, "check_runs": []})
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
        if self.path == "/repos/o/r/pulls/28/merge" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"merged": True, "sha": "c" * 40})
        if self.path == "/repos/o/r/pulls/26/merge" and self.auth() in (TOKEN, PAT):
            return self.send(200, {"merged": True, "sha": "c" * 40})
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
