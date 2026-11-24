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
  11 head(0*40)的 pipeline 第 3 次查詢起才出現(晚登記的外部 CI)
  13 目標分支 tgtci 的 commit(1*40)有 commit status(head 沒有)
  14 MR 自己有 pipeline(detached,不掛在 head SHA)
  15 查詢 head(9*40)的 pipelines 回 500
  16 目標分支 gone 不存在(查分支 404)
  17 不帶 recheck 的 GET 還是舊 sha(0*40)與 has_conflicts(剛 push 完);重新計算後才是 a*40(第一次查詢不論帶不帶 recheck)
  18 detailed_merge_status=ci_still_running(專案規定 pipeline 成功才能合併)
  有 CI 時「pipeline 通過才合併」(head 都有 .gitlab-ci.yml,除了 24):
  19 head 4*40:head pipeline success;同一個 ref 舊的 pipeline 失敗、重跑成功;commit status 有 allow_failure 的失敗與 manual → 可合併
  20 head 5*40:head pipeline failed → 結束碼 2
  21 head 6*40:head pipeline 前 2 次 MR 查詢(帶 recheck)是 running,之後 success(等 CI 跑完)
  22 head 7*40:head pipeline success,但外部 commit status(jenkins)failed → 結束碼 2
  23 head 8*40:head pipeline 是舊 head 的(sha 不同、ref 是分支)→ 等;不等時結束碼 4
  24 head a*40:沒有 CI 檔,MR 有 merged results pipeline(ref refs/merge-requests/24/merge,sha 是合併用的 commit)success → 可合併
分支 → commit:develop / main → 2*40,withci → 3*40(有 .gitlab-ci.yml),tgtci → 1*40;其他 404。
專案預設回傳 Maintainer 看得到的 CI 欄位(ci_config_path "",兩個布林 false);
情境 {"hide_fields": [...]} 拿掉欄位(模擬 Developer 權限),{<欄位>: 值} 覆寫。
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
G, T1, T2, T3, N = "0" * 40, "1" * 40, "2" * 40, "3" * 40, "9" * 40
BRANCHES = {"develop": T2, "main": T2, "withci": T3, "tgtci": T1}
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
    11: mr(11, sha=G),
    13: mr(13, target="tgtci"),
    14: mr(14),
    15: mr(15, sha=N),
    16: mr(16, target="gone"),
    17: mr(17),
    18: mr(18),
    19: mr(19, sha="4" * 40),
    20: mr(20, sha="5" * 40),
    21: mr(21, sha="6" * 40),
    22: mr(22, sha="7" * 40),
    23: mr(23, sha="8" * 40),
    24: mr(24),
}
S4, S5, S6, S7, S8 = "4" * 40, "5" * 40, "6" * 40, "7" * 40, "8" * 40
CI_FILE_REFS = {C, T3, S4, S5, S6, S7, S8}
PIPELINES = {D: [{"id": 1, "status": "running"}],
             S4: [{"id": 30, "ref": "feat/19", "status": "success"}, {"id": 29, "ref": "feat/19", "status": "failed"}],
             S5: [{"id": 31, "ref": "feat/20", "status": "failed"}],
             S7: [{"id": 33, "ref": "feat/22", "status": "success"}],
             S8: []}
STATUSES = {E: [{"name": "jenkins", "status": "pending"}], T1: [{"name": "jenkins", "status": "success"}],
            S4: [{"name": "test", "status": "success", "allow_failure": False},
                 {"name": "lint", "status": "failed", "allow_failure": True},
                 {"name": "deploy", "status": "manual", "allow_failure": True}],
            S5: [{"name": "test", "status": "failed", "allow_failure": False}],
            S7: [{"name": "test", "status": "success", "allow_failure": False},
                 {"name": "jenkins", "status": "failed", "allow_failure": False}]}
HEAD_PIPELINES = {19: {"id": 30, "sha": S4, "ref": "feat/19", "status": "success"},
                  20: {"id": 31, "sha": S5, "ref": "feat/20", "status": "failed"},
                  22: {"id": 33, "sha": S7, "ref": "feat/22", "status": "success"},
                  23: {"id": 34, "sha": "c" * 40, "ref": "feat/23", "status": "success"},
                  24: {"id": 40, "sha": "b" * 40, "ref": "refs/merge-requests/24/merge", "status": "success"}}
MR_PIPELINES = {14: [{"id": 7, "status": "running"}], 24: [{"id": 40, "status": "success"}]}
LATE = {}  # sha → pipelines 查詢次數
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
            sc = scenario()
            proj.update({"ci_config_path": "", "auto_devops_enabled": False, "only_allow_merge_if_pipeline_succeeds": False})
            for k in ("ci_config_path", "auto_devops_enabled", "only_allow_merge_if_pipeline_succeeds"):
                if k in sc:
                    proj[k] = sc[k]
            for k in sc.get("hide_fields", []):
                proj.pop(k, None)
            return self.send(200, proj)
        if not p.startswith(PROJ + "/"):
            return self.send(404, {"message": "404 Not Found " + p})
        rest = p[len(PROJ) + 1:]
        if rest == "protected_branches":
            if "prot_status" in scenario():
                return self.send(scenario()["prot_status"], {"message": "403 Forbidden"})
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
        if rest.startswith("repository/branches/"):
            b = unquote(rest[len("repository/branches/"):])
            if b not in BRANCHES:
                return self.send(404, {"message": "404 Branch Not Found"})
            return self.send(200, {"name": b, "commit": {"id": BRANCHES[b]}})
        if rest.startswith("merge_requests/") and rest.endswith("/pipelines"):
            iid = int(rest.split("/")[1])
            if iid == 21:
                return self.send(200, [{"id": 32, "status": "success" if RECHECK.get(21, 0) > 2 else "running"}])
            return self.send(200, MR_PIPELINES.get(iid, []))
        if rest.startswith("merge_requests/"):
            iid = int(rest.split("/")[1])
            if iid not in MRS:
                return self.send(404, {"message": "404 Not found"})
            m = dict(MRS[iid])
            if iid == 17 and RECHECK.get(17, 0) == 0:  # 剛 push 完:第一次查詢是舊 sha、舊衝突狀態,還在 checking
                RECHECK[17] = 1
                m.update(sha="0" * 40, has_conflicts=True, detailed_merge_status="checking")
            if iid == 18:
                m["detailed_merge_status"] = "ci_still_running"
            if iid in HEAD_PIPELINES:
                m["head_pipeline"] = dict(HEAD_PIPELINES[iid])
            if iid == 21:
                n = RECHECK.get(21, 0)
                if q.get("with_merge_status_recheck") == ["true"]:
                    RECHECK[21] = n + 1
                done = RECHECK[21] > 2 if 21 in RECHECK else False
                m["head_pipeline"] = {"id": 32, "sha": S6, "ref": "feat/21", "status": "success" if done else "running"}
                if not done:
                    m["detailed_merge_status"] = "ci_still_running"
            if iid == 3:
                n = RECHECK.get(iid, 0)
                if q.get("with_merge_status_recheck") == ["true"]:
                    RECHECK[iid] = n + 1
                m["detailed_merge_status"] = "unchecked" if n < 2 else "checking" if n < 3 else "mergeable"
            return self.send(200, m, control_chars=(iid == 2))
        if rest == "pipelines":
            sha = q.get("sha", [""])[0]
            if sha == N:
                return self.send(500, {"message": "500 Internal Server Error"})
            if sha == G:
                LATE[G] = LATE.get(G, 0) + 1
                return self.send(200, [{"id": 9, "status": "pending"}] if LATE[G] >= 3 else [])
            if sha == S6:
                return self.send(200, [{"id": 32, "ref": "feat/21", "status": "success" if RECHECK.get(21, 0) > 2 else "running"}])
            return self.send(200, PIPELINES.get(sha, []))
        if rest == "pipelines/50/jobs":
            return self.send(200, [{"id": 501, "stage": "test", "name": "go-test", "status": "failed", "allow_failure": False},
                                   {"id": 502, "stage": "test", "name": "lint", "status": "failed", "allow_failure": True}])
        if rest == "jobs/501/trace":  # 純文字、含 ANSI 色碼與 section 標記
            b = "".join(f"line {i}\n" for i in range(1, 301)) + "\x1b[31;1m--- FAIL: TestX\x1b[0m\nsection_end:1700000000:step_script\r\x1b[0KERROR: Job failed\n"
            self.send_response(200); self.send_header("Content-Type", "text/plain"); self.send_header("Content-Length", str(len(b.encode())))
            self.end_headers(); return self.wfile.write(b.encode())
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
            LATE.clear()
            return self.send(200, {})
        if self.token() is None:
            return self.send(401, {"message": "401 Unauthorized"})
        if p == PROJ + "/pipelines/50/retry":
            return self.send(201, {"id": 50, "status": "pending"})
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
        if p.startswith(PROJ + "/merge_requests/") and p.endswith("/rebase"):
            iid = int(p.split("/")[-2])
            if iid not in MRS or MRS[iid]["state"] != "opened":
                return self.send(403, {"message": "403 Forbidden"})
            MRS[iid]["sha"] = "7" * 40  # 伺服器端 rebase 後的新 head
            return self.send(202, {"rebase_in_progress": True})
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
