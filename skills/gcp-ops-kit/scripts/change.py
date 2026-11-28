"""執行使用者逐條核准的變更。由 change.sh 呼叫。

change.sh <plan.json> --sha <sha256> --approved "使用者已核准變更 C1, C3"
stdout:status=PASS|ISSUES|BLOCKED、run=<變更 run 目錄>、每條結果
結束碼:0 PASS、1 ISSUES、3 BLOCKED、2 用法錯誤
"""
import json
import os
import re
import shlex
import subprocess
import sys
import time

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.realpath(__file__)))

import gglib
import ggchange
import ggplan

APPROVE_PREFIX = "使用者已核准變更"
OP_POLL_SECONDS = float(os.environ.get("GG_OP_POLL", "15"))
OP_FAIL_WINDOW = float(os.environ.get("GG_OP_FAIL_WINDOW", "600"))  # 連續查不到狀態超過 10 分鐘才放棄
CHANGE_TIMEOUT_SQL = 3600
CHANGE_TIMEOUT_GKE = int(os.environ.get("GG_GKE_TIMEOUT", "14400"))  # GKE 操作可能很久:預設 4 小時
STATE_STABLE = float(os.environ.get("GG_STATE_STABLE", "120"))  # 依資源狀態判斷完成時,要連續穩定多久


def _settled(svc, after):
    """資源是否不在變更中:GKE 叢集 / node pool 是 RUNNING(resize 另看 MIG 是否穩定),Cloud SQL 是 RUNNABLE。"""
    if not isinstance(after, dict):
        return False
    if svc == "sql":
        return after.get("state") in (None, "RUNNABLE")
    np = after.get("nodepool") if isinstance(after.get("nodepool"), dict) else after
    return np.get("status") in (None, "RUNNING") and all(x in (None, True) for x in (after.get("mig_stable") or []))


VERIFY_WAIT = int(os.environ.get("GG_VERIFY_WAIT", "600"))  # resize 驗證最多等幾秒
VOLATILE = ("status", "managedFields", "resourceVersion", "uid", "creationTimestamp", "generation", "selfLink")


APPROVE_RE = re.compile(r"^使用者已核准變更\s*(C[1-9][0-9]{0,2}(?:\s*[,\uff0c\u3001]\s*C[1-9][0-9]{0,2})*)\s*$")


def parse_approved(text):
    """固定格式:「使用者已核准變更 C1, C3」(逗號或頓號分隔,不可有其他文字)。"""
    m = APPROVE_RE.match((text or "").strip())
    if not m:
        raise gglib.Blocked("核准旗標格式不對:要完全是「使用者已核准變更 C1, C3」(只有編號與逗號,不可夾其他文字)")
    ids = re.findall(r"C[1-9][0-9]{0,2}", m.group(1))
    return sorted(set(ids), key=lambda x: int(x[1:]))


def rollback_object(o):
    o = json.loads(json.dumps(o))
    md = o.get("metadata") or {}
    for k in VOLATILE:
        md.pop(k, None)
    o.pop("status", None)
    return o  # 保留 last-applied 註解,replace 後與變更前一致


def _flag(argv, name):
    for a in argv:
        if a.startswith(name + "="):
            return a.split("=", 1)[1]
    return None


class Runner:
    def __init__(self, cfg, plan, plan_path, approved):
        self.cfg, self.plan, self.plan_path, self.approved = cfg, plan, plan_path, approved
        self.project = plan["project"]
        self.results = []
        self.status = "PASS"
        self.inflight = None

    def stop(self, status, cid, msg):
        self.results.append({"id": cid, "result": "BLOCKED" if status == "BLOCKED" else "失敗", "reason": msg})
        executed = any(str(r.get("result", "")).startswith("已執行") or r.get("rc") == 0 for r in self.results)
        # 已經有條目改了雲端:整體不能回 BLOCKED(那代表「事前檢查不過、什麼都沒改」)
        self.status = "ISSUES" if executed else status
        return False

    def wait_operation(self, s, svc, r, argv):
        """--async 送出後輪詢操作狀態(每次輪詢前換 token)。回傳和 subprocess 相同形狀的結果:
        DONE 且沒有錯誤 → rc 0;操作錯誤 → rc 1;讀不到操作名稱、連續查不到狀態、逾時或任何例外 → rc 124(狀態不明)。"""
        unknown = lambda msg: subprocess.CompletedProcess(r.args, 124, "", msg)
        try:
            try:
                op = json.loads(r.stdout or "null")
            except ValueError:
                op = None
            if isinstance(op, list):
                op = op[0] if op else None
            is_op = isinstance(op, dict) and (op.get("operationType") or op.get("kind") == "sql#operation"
                                              or "/operations/" in str(op.get("selfLink") or op.get("name") or ""))
            name = (op.get("name") or "").rsplit("/", 1)[-1] if is_op else ""  # 印出的不是操作(例如資源本身):改用差集找
            if not name:
                # gcloud 原始碼:container clusters update / resize 加 --async 時不印操作。
                # 不去猜哪個操作是自己的:改由 one() 依資源狀態(回到 RUNNING 且符合預期值)判斷完成
                self.wait_state = True
                return subprocess.CompletedProcess(r.args, 0, "", "")
            if op.get("status") == "DONE":
                return self._op_result(r, svc, op)
            project = _flag(argv, "--project")
            loc = _flag(argv, "--location")
            deadline = time.time() + (CHANGE_TIMEOUT_GKE if svc == "container" else CHANGE_TIMEOUT_SQL)
            fail_since, last_err = None, ""
            while time.time() < deadline:
                time.sleep(OP_POLL_SECONDS)
                args = (["container", "operations", "describe", name, f"--location={loc}"] if svc == "container"
                        else ["sql", "operations", "describe", name])
                try:
                    q = s.gcloud(args + [f"--project={project}", "--format=json", "--quiet"], mode="dryrun")
                except gglib.Blocked as e:  # 換 token 暫時失敗:當成一次查詢失敗
                    q = subprocess.CompletedProcess(args, 1, "", str(e))
                try:
                    st = json.loads(q.stdout or "null") if q.returncode == 0 else None
                except ValueError:
                    st = None
                if not isinstance(st, dict):
                    last_err = gglib._short(q.stderr, 300) or "回應不是 JSON 物件"
                    if re.search(r"PERMISSION_DENIED|\bHTTP(?:Error)? ?403\b|\b403\b(?=[: ]+(?:Forbidden|PERMISSION))", last_err):  # NOT_FOUND 可能是最終一致:照樣在時間窗內重試
                        return unknown(f"查不到操作 {name} 的狀態(不會恢復的錯誤):{last_err}")
                    fail_since = fail_since or time.time()
                    if time.time() - fail_since >= OP_FAIL_WINDOW:
                        return unknown(f"連續 {int(time.time() - fail_since)} 秒查不到操作 {name} 的狀態:{last_err}")
                    continue
                fail_since = None
                if st.get("status") == "DONE":
                    return self._op_result(r, svc, st)
            return unknown(f"等待操作 {name} 逾時")
        except Exception as e:  # 輪詢中任何錯誤(例如換 token 失敗):指令已送出 → 狀態不明
            return unknown(f"輪詢操作狀態時出錯({type(e).__name__}: {gglib._short(str(e), 200)})")

    @staticmethod
    def _op_result(r, svc, st):
        err = st.get("error")
        if not err and svc == "container" and str(st.get("statusMessage") or "").strip():
            # DONE、沒有 error 但帶 statusMessage:當成功並照常驗證(沒有預期值時記狀態不明),訊息附在紀錄裡
            return subprocess.CompletedProcess(r.args, 0, json.dumps(st, ensure_ascii=False),
                                               "操作 DONE,附帶訊息:" + gglib._short(str(st.get("statusMessage")), 300))
        return subprocess.CompletedProcess(r.args, 1 if err else 0, json.dumps(st, ensure_ascii=False),
                                           json.dumps(err, ensure_ascii=False) if err else "")

    def precheck_static(self):
        byid = {it["id"]: it for it in self.plan["items"]}
        for cid in self.approved:
            it = byid.get(cid)
            if not it:
                raise gglib.Blocked(f"{cid} 不在計畫中")
            if it.get("blocked_reason"):
                raise gglib.Blocked(f"{cid} 在計畫中已是 BLOCKED:{it['blocked_reason']}")
            if not it.get("reversible"):
                raise gglib.Blocked(f"{cid} 不可還原,請使用者自己執行")
            if it.get("target", {}).get("project") != self.project:
                raise gglib.Blocked(f"{cid} 的 target 專案不符")
            shape = ggchange.classify(ggplan.materialize(it, self.run), self.cfg, shape_only=True)
            if shape["blocked_reason"] or shape["kind"] != it["kind"]:
                raise gglib.Blocked(f"{cid} 重新分類不符:{shape['blocked_reason'] or shape['kind']}")
        return [byid[c] for c in self.approved]

    def execute(self, run):
        self.run = run
        items = self.precheck_static()
        if not os.path.exists(os.path.join(os.path.dirname(self.plan_path), "approval.json")):
            raise gglib.Blocked("核准檔已被使用或不存在(每份核准只能執行一次,請使用者重新核准)")
        self.consumed = False
        ctx_done = set()
        with gglib.Session(self.cfg, run, self.project, "change") as s:
            for n, it in enumerate(items):
                try:
                    ok = self.one(s, it, ctx_done)
                except Exception as e:  # 任何非預期錯誤:依「指令送出了沒」分別記錄,然後停止
                    msg = f"{type(e).__name__}: {gglib._short(str(e), 300)}"
                    existing = [x for x in self.results if x.get("id") == it["id"]]
                    if existing:  # 指令已成功,之後的步驟出錯:更新同一列
                        existing[0].update({"result": "已執行(後續步驟錯誤)", "reason": msg + ";請先確認現況"})
                        self.status = "ISSUES"
                    elif self.inflight:  # 指令送出後出錯:狀態不明
                        self.inflight.update({"result": "錯誤(狀態不明)", "reason": msg + ";請先確認現況"})
                        self.results.append(self.inflight)
                        self.inflight = None
                        self.status = "ISSUES"
                    else:  # 指令還沒送出:雲端沒被動到
                        self.stop("BLOCKED", it["id"], "執行前發生錯誤:" + msg)
                    ok = False
                if not ok:
                    for rest in items[n + 1:]:
                        self.results.append({"id": rest["id"], "result": "未執行", "reason": f"{it['id']} 未成功,之後停止"})
                    break
        return self.status

    def one(self, s, it, ctx_done):
        cid = it["id"]
        self.wait_state = False  # 每條重設:上一條的狀態不影響這條
        self.op_note = False
        argv = ggplan.materialize(it, self.run)
        kind = it["kind"]
        try:
            snap, endpoint, err = ggplan.snapshot(s, kind, argv, self.project, ctx_done)
        except (gglib.Blocked, gglib.Denied) as e:
            return self.stop("BLOCKED", cid, str(e))
        if err:
            return self.stop("BLOCKED", cid, "變更前快照失敗:" + err)
        needs_ep = argv[0] == "kubectl" or kind == "gke-resize"
        if needs_ep and (not endpoint or not it["target"].get("endpoint")):
            return self.stop("BLOCKED", cid, "讀不到叢集 endpoint,不能確認是同一個叢集")
        if needs_ep and endpoint != it["target"].get("endpoint"):
            return self.stop("BLOCKED", cid, f"叢集 endpoint 不符(計畫 {it['target'].get('endpoint')},現在 {endpoint})")
        bad = ggplan.check_pre(it.get("precondition") or [], snap) + ggplan.check_pre(it.get("auto_pre") or [], snap, redacted=False)
        if bad:
            return self.stop("BLOCKED", cid, "precondition 不符(環境已變):" + json.dumps(bad, ensure_ascii=False)[:500])
        dry = {}
        if kind in ("kubectl-apply", "kubectl-patch"):
            try:
                created, new_f, log, err = ggplan.k8s_dryrun(s, kind, argv, snap)
            except (gglib.Blocked, gglib.Denied) as e:
                return self.stop("BLOCKED", cid, "dry-run 被拒絕:" + str(e))
            dry = {"log": [{"step": a, "rc": b} for a, b, _ in log]}
            if err:
                return self.stop("BLOCKED", cid, "dry-run 失敗:" + err)
            res = ggchange.classify(argv, self.cfg, snap, new_f, created)
        else:
            res = ggchange.classify(argv, self.cfg, snap)
        if res.get("rollback"):
            res["rollback"] = [a.replace("<before/C?.json>", f"<變更 run>/before/{cid}.rollback.json") for a in res["rollback"]]
        for k in ("kind", "reversible", "loosens_security", "rollback"):
            if res[k] != it.get(k):
                return self.stop("BLOCKED", cid, f"重新計算的 {k}={res[k]} 與計畫 {it.get(k)} 不符")
        if res["blocked_reason"]:
            return self.stop("BLOCKED", cid, "重新計算後 BLOCKED:" + res["blocked_reason"])
        gglib.write_json(os.path.join(self.run, "before", f"{cid}.json"), gglib.redact(snap))
        if argv[0] == "kubectl" and kind in ("kubectl-apply", "kubectl-patch"):
            objs = snap.get("objects") if kind == "kubectl-apply" else [snap]
            rb = {"apiVersion": "v1", "kind": "List", "items": [rollback_object(o) for o in objs if not o.get("_absent")]}
            p = os.path.join(self.run, "before", f"{cid}.rollback.json")
            gglib.write_json(p, rb)
        kinfo = ggchange.change_rules()["kinds"][kind]
        if kinfo.get("async") and not _settled(kinfo["async"], snap):
            return self.stop("BLOCKED", cid, "資源正在變更中(不是 RUNNING / MIG 不穩定),這條沒送出;請等目前的操作完成後重試")
        left = ("核准已用掉(前面的條目已送出),剩下的條目需重新核准" if self.consumed else "雲端沒被動到、核准檔還在,請稍後重試")
        try:
            s.ensure_fresh(margin=180, strict=True)  # 帳號模式:作廢核准檔前先換好 token(提早 3 分鐘,之後送出前不必再換);失敗代表指令還沒送出、核准檔也還在
        except gglib.Blocked as e:
            return self.stop("BLOCKED", cid, "送出前取得 token 失敗:" + str(e) + ";" + left)
        if not self.consumed:
            # 第一條指令真正送出前才作廢核准檔(改名,原子):之前的檢查失敗不會浪費核准
            src = os.path.join(os.path.dirname(self.plan_path), "approval.json")
            try:
                os.rename(src, os.path.join(os.path.dirname(self.plan_path), f"approval.used-{os.path.basename(self.run)}.json"))
            except OSError:
                return self.stop("BLOCKED", cid, "核准檔已被使用或不存在(每份核准只能執行一次)")
            self.consumed = True
        # 先記「執行中」:若在執行途中被中斷,紀錄仍會有這條與還原指令
        self.inflight = {"id": cid, "kind": kind, "argv": it["command"], "result": "執行中被中斷(狀態不明)",
                         "reason": "指令已送出但沒有等到結果;請先確認現況",
                         "rollback": [a.replace("<變更 run>", self.run) for a in (it.get("rollback") or [])],
                         "rollback_warning": it.get("rollback_warning"), "exec_warning": it.get("exec_warning")}
        run_argv = argv + (["--async", "--format=json"] if kinfo.get("async") else [])
        try:
            # 帳號模式的 token 至少剩約 10 分鐘:不走 --async 的指令逾時 8 分鐘(留餘裕,避免中途過期)
            tmo = 300 if kinfo.get("async") else (480 if self.cfg.get("GG_AUTH") == "user" else 1800)
            r = s._exec(run_argv, "change", timeout=tmo)
        except (gglib.Denied, gglib.Blocked) as e:  # 執行前被拒絕或取不到 token:雲端沒被動到
            self.inflight = None
            return self.stop("BLOCKED", cid, "執行前被拒絕:" + str(e))
        if r.returncode == 0 and kinfo.get("async"):
            r = self.wait_operation(s, kinfo["async"], r, argv)
            self.op_note = r.returncode == 0 and (r.stderr or "").startswith("操作 DONE,附帶訊息")
        rec = {"id": cid, "kind": kind, "argv": it["command"], "rc": r.returncode, "dry_run": dry,
               "stderr": gglib._short(r.stderr, 800)}
        if it.get("exec_warning"):
            rec["exec_warning"] = it["exec_warning"]
        if r.returncode != 0:
            rec["rollback"] = [a.replace("<變更 run>", self.run) for a in (it.get("rollback") or [])]
            if r.returncode == 124:
                rec.update({"result": "狀態不明", "reason": (gglib._short(r.stderr, 300) or "等待逾時") + ";伺服器端的操作可能仍在進行,請先確認現況(gcloud container / sql operations list)"})
            else:
                rec.update({"result": "失敗(可能部分套用)", "reason": f"指令失敗(rc={r.returncode});請先確認現況再決定是否還原"})
            self.results.append(rec)
            self.inflight = None  # 先登記結果再清 inflight:中間被中斷也不會漏掉這條
            self.status = "ISSUES"
            return False
        rec["rollback"] = [a.replace("<變更 run>", self.run) for a in (it.get("rollback") or [])]
        if it.get("rollback_warning"):
            rec["rollback_warning"] = it["rollback_warning"]
        if it.get("rollback_note"):
            rec["rollback_note"] = it["rollback_note"]
        # 指令已成功:立刻記錄(驗證期間被中斷也留得下這條與還原指令),之後就地更新結果
        rec.update({"result": "已執行(驗證中被中斷)", "reason": "指令已成功執行,驗證尚未完成"})
        self.results.append(rec)
        self.inflight = None
        exp = it.get("expected") or []
        note = ("操作完成但帶有訊息:" + gglib._short(r.stderr, 200)) if self.op_note else ""
        if (self.wait_state or self.op_note) and not exp:
            # 依資源狀態判斷完成、或 DONE 但帶 statusMessage:沒有預期值可驗證就不能確定成功
            why = "gcloud 沒印出操作,只能依資源狀態判斷" if self.wait_state else note
            rec.update({"result": "狀態不明", "reason": why + ";這條沒有預期值可驗證,請先確認現況"})
            self.status = "ISSUES"
            return False
        if self.wait_state:  # 沒有操作可追:等資源回到 RUNNING 且符合預期值(最多 GKE 逾時)
            deadline = time.time() + CHANGE_TIMEOUT_GKE
        else:
            deadline = time.time() + (VERIFY_WAIT if kind == "gke-resize" else 0)
        svc = kinfo.get("async")
        stable_since, err_since = None, None
        while True:
            try:
                after, _, err = ggplan.snapshot(s, kind, argv, self.project, ctx_done)
            except (gglib.Blocked, gglib.Denied) as e:
                after, err = None, str(e)
            if self.wait_state:
                # 沒有操作可追:要連續 STATE_STABLE 秒都「不在變更中且符合預期值」才算完成;快照暫時失敗在時間窗內重試
                now = time.time()
                if err:
                    err_since = err_since or now
                    stable_since = None
                    if now - err_since >= OP_FAIL_WINDOW or now >= deadline:
                        rec.update({"result": "狀態不明", "reason": f"gcloud 沒印出操作,且連續查不到資源狀態:{gglib._short(err, 200)};請先確認現況"})
                        self.status = "ISSUES"
                        return False
                else:
                    err_since = None
                    good = _settled(svc, after) and not ggplan.check_pre(exp, after)
                    stable_since = (stable_since or now) if good else None
                    if good and now - stable_since >= STATE_STABLE:
                        break
                    if now >= deadline:
                        rec.update({"result": "狀態不明", "reason": "gcloud 沒印出操作;等到逾時,資源仍在變更中或不符預期值,伺服器端可能仍在進行,請先確認現況"})
                        self.status = "ISSUES"
                        return False
                time.sleep(OP_POLL_SECONDS)
                continue
            # resize:新節點要一段時間才加入叢集,驗證不符時等一下再看
            if err or not exp or not ggplan.check_pre(exp, after) or time.time() >= deadline:
                break
            time.sleep(15)
        if err:
            rec.update({"result": "已執行(驗證失敗)", "reason": "指令已成功執行,但變更後快照失敗:" + err})
            self.status = "ISSUES"
            return False
        gglib.write_json(os.path.join(self.run, "after", f"{cid}.json"), gglib.redact(after))
        if kind == "kubectl-rollout-restart" and not exp:
            ptr = "/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt"
            okv = gglib.ptr_get(after, ptr) not in (None, gglib.ptr_get(snap, ptr))
            badexp = [] if okv else [{"cond": {"field": ptr}, "actual": "未更新"}]
        else:
            badexp = ggplan.check_pre(exp, after)
        if badexp:
            rec.update({"result": "已執行(驗證失敗)", "reason": "驗證不符:" + json.dumps(badexp, ensure_ascii=False)[:500]})
            self.status = "ISSUES"
            return False
        rec.update({"result": "已執行", "reason": "驗證符合" + (";依資源狀態判斷完成(gcloud 沒印出操作)" if self.wait_state else "") + (";" + note if note else "")})
        return True


def write_log(run, plan_path, sha, approved, runner):
    lines = [f"# 變更紀錄", "", f"- 計畫:`{plan_path}`", f"- plan sha256:`{sha}`", f"- 核准:{', '.join(approved)}",
             f"- 狀態:**{runner.status}**", f"- 時間:{gglib.now_iso()}", "",
             "| C | 結果 | 原因 / 驗證 | 結束碼 | 還原指令 |", "|---|---|---|---|---|"]
    def cell(x):
        return str(x).replace("|", "\\|").replace("\r", "").replace("\n", "<br>")
    for r in runner.results:
        rb = shlex.join(r.get("rollback") or []) or r.get("rollback_note") or "-"
        warn = (f"<br>⚠ {r['rollback_warning']}" if r.get("rollback_warning") else "") + (f"<br>⚠ 執行前注意:{r['exec_warning']}" if r.get("exec_warning") else "")
        lines.append(f"| {cell(r['id'])} | {cell(r['result'])} | {cell(r.get('reason', ''))} | {r.get('rc', '-')} | `{cell(rb)}`{cell(warn)} |")
    lines += ["", "實際執行的指令見 `inventory/commands.log`(由 kit 記錄,agent 不寫此檔)。", ""]
    with open(os.path.join(run, "change-log.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    gglib.write_json(os.path.join(run, "change.json"),
                     {"plan": plan_path, "sha256": sha, "approved": approved, "status": runner.status,
                      "results": runner.results})


def main(argv):
    gglib.install_signal_handlers()
    if len(argv) != 5 or argv[1] != "--sha" or argv[3] != "--approved":
        gglib.die(__doc__, gglib.EXIT_USAGE)
    plan_path, sha, approved_text = os.path.realpath(argv[0]), argv[2].strip().lower(), argv[4]
    run = None
    cfg = None
    project = None
    try:
        cfg = gglib.load_config(require=True)
        if not plan_path.startswith(os.path.realpath(cfg["GG_REPORT_DIR"]) + os.sep):
            raise gglib.Blocked("plan.json 不在 GG_REPORT_DIR 底下")
        src_run = os.path.dirname(plan_path)
        src_meta = gglib.read_json(os.path.join(src_run, "meta.json"), {}) or {}
        if os.path.basename(plan_path) != "plan.json" or src_meta.get("mode") not in ("review", "plan"):
            raise gglib.Blocked("只接受審查 / 計畫 run 目錄裡由 plan.py 產生的 plan.json")
        import hashlib
        with open(plan_path, "rb") as f:
            raw = f.read()  # 只讀一次:雜湊與執行用同一份內容
        actual = hashlib.sha256(raw).hexdigest()
        if actual != sha:
            raise gglib.Blocked(f"plan.json sha256 不符(簡報 {sha[:12]}…,實際 {actual[:12]}…)")
        try:
            plan = json.loads(raw.decode("utf-8"))
        except ValueError:
            raise gglib.Blocked("plan.json 不是有效 JSON")
        if not plan or os.path.realpath(plan.get("source_run") or "") != src_run or plan.get("project") != src_meta.get("project"):
            raise gglib.Blocked("plan.json 的 source_run / project 與所在 run 目錄不符")
        # 計畫時的身分要和現在相同:避免計畫後切換 gcloud 帳號,用使用者沒確認過的身分執行
        # 比對 plan.json(已算進 sha256)記的身分,不是 meta.json
        if (plan.get("auth") or "sa") != cfg.get("GG_AUTH") or (plan.get("sa") or "").lower() != (cfg.get("GG_SA") or "").lower():
            raise gglib.Blocked(f"計畫時的身分({plan.get('auth')}:{plan.get('sa')})和現在({cfg.get('GG_AUTH')}:{cfg.get('GG_SA')})不同;"
                                "請用同一個身分重新產生計畫")
        approved = parse_approved(approved_text)
        # 核准檔:由主 agent 依使用者原話寫在計畫 run 目錄(gcp-guardian 的 hook 不准寫這個檔),旗標必須與它一致
        appr = gglib.read_json(os.path.join(src_run, "approval.json"), None)
        if not isinstance(appr, dict):
            raise gglib.Blocked(f"缺核准檔 {os.path.join(src_run, 'approval.json')}(由主 agent 在使用者核准後寫入)")
        if str(appr.get("sha256", "")).strip().lower() != sha or sorted(set(appr.get("approved") or []), key=lambda x: int(str(x)[1:]) if str(x)[1:].isdigit() else 0) != approved:
            raise gglib.Blocked("核准旗標與核准檔(approval.json)的 sha256 / 編號不一致")
        project = gglib.check_project(plan["project"])
        run = gglib.new_run(cfg, project, "change")
        meta = gglib.read_json(os.path.join(run, "meta.json"))
        meta.update({"plan": plan_path, "plan_sha256": sha, "approved": approved, "source_run": plan.get("source_run")})
        gglib.write_json(os.path.join(run, "meta.json"), meta)
        runner = Runner(cfg, plan, plan_path, approved)
        try:
            gglib.acquire_lock(cfg, project, "change", run)
            status = runner.execute(run)
        except (gglib.Blocked, gglib.Denied) as e:
            if runner.inflight:  # 指令已送出後才出錯:保留這條與還原指令
                runner.results.append(runner.inflight)
            runner.status = "ISSUES" if runner.inflight or any(r.get("rc") == 0 for r in runner.results) else "BLOCKED"
            runner.results.append({"id": "-", "result": "BLOCKED", "reason": str(e)})
            status = runner.status
        except SystemExit:
            # 被中斷(例如逾時被砍):先寫紀錄(含已執行 / 執行中條目的還原指令)再結束
            if runner.inflight:
                runner.results.append(runner.inflight)
            runner.status = "ISSUES" if runner.inflight or any(r.get("rc") == 0 for r in runner.results) else "BLOCKED"
            runner.results.append({"id": "-", "result": "中斷", "reason": "change.sh 被中斷;進行中的雲端操作可能仍在跑,請先確認現況"})
            gglib.release_lock(cfg, project, run)
            write_log(run, plan_path, sha, approved, runner)
            try:
                subprocess.run(["node", os.path.join(gglib.KIT, "scripts", "render.mjs"), run], timeout=60)
            except Exception:
                pass
            print(f"status={runner.status}")
            print(f"run={run}")
            for r in runner.results:
                print(f"{r['id']}\t{r['result']}\t{r.get('reason', '')}\t{shlex.join(r.get('rollback') or [])}", flush=True)
            raise
        except Exception as e:
            if runner.inflight:
                runner.results.append(runner.inflight)
            runner.status = "ISSUES" if runner.inflight or any(r.get("rc") == 0 for r in runner.results) else "BLOCKED"
            runner.results.append({"id": "-", "result": "錯誤", "reason": f"{type(e).__name__}: {gglib._short(str(e), 300)}"})
            status = runner.status
        finally:
            gglib.release_lock(cfg, project, run)
        write_log(run, plan_path, sha, approved, runner)
        subprocess.run(["node", os.path.join(gglib.KIT, "scripts", "render.mjs"), run])
        print(f"status={status}")
        print(f"run={run}")
        for r in runner.results:
            print(f"{r['id']}\t{r['result']}\t{r.get('reason', '')}\t{shlex.join(r.get('rollback') or [])}"
                  + (f"\t⚠ {r['rollback_warning']}" if r.get("rollback_warning") else "")
                  + (f"\t⚠ 執行前注意:{r['exec_warning']}" if r.get("exec_warning") else ""))
        return {"PASS": 0, "ISSUES": 1, "BLOCKED": 3}[status]
    except gglib.Blocked as e:
        print("status=BLOCKED")
        if run:
            print(f"run={run}")
        print(f"BLOCKED: {e}", file=sys.stderr)
        return gglib.EXIT_BLOCKED
    except gglib.Denied as e:
        print("status=BLOCKED")
        print(f"DENIED: {e}", file=sys.stderr)
        if cfg and project and run:
            gglib.release_lock(cfg, project, run)
        return gglib.EXIT_BLOCKED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
