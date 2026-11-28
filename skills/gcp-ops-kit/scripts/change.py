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
import datetime as _dt

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.realpath(__file__)))

import gglib
import ggchange
import ggplan

APPROVE_PREFIX = "使用者已核准變更"
OP_POLL_SECONDS = float(os.environ.get("GG_OP_POLL", "15"))
OP_FAIL_WINDOW = float(os.environ.get("GG_OP_FAIL_WINDOW", "600"))  # 連續查不到狀態超過 10 分鐘才放棄
CHANGE_TIMEOUT_SQL = 3600
CHANGE_TIMEOUT_GKE = int(os.environ.get("GG_GKE_TIMEOUT", "14400"))  # GKE 操作可能很久:預設 4 小時
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


def _parse_time(t):
    """GKE 的時間有 9 位小數(奈秒),Python 3.9 的 fromisoformat 不接受:先截到 6 位。"""
    t = re.sub(r"\.(\d+)", lambda m: "." + m.group(1)[:6].ljust(6, "0"), str(t), count=1).replace("Z", "+00:00")  # 小數補 / 截成 6 位
    try:
        return _dt.datetime.fromisoformat(t).timestamp()
    except ValueError:
        return None


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
            name = (op.get("name") or "").rsplit("/", 1)[-1] if isinstance(op, dict) else ""
            if not name:  # gcloud --async 可能不印操作:在時間窗內重查這個資源在送出後開始的操作
                op = {}
                t_end = time.time() + OP_FAIL_WINDOW
                while True:
                    try:
                        name = self._find_operation(s, svc, argv)
                    except gglib.Blocked:
                        name = ""  # 換 token 暫時失敗:當成這次沒找到
                    if name == "MULTI":
                        return unknown("指令已送出,但同時有多個可能的操作,無法確定是哪一個;請用 gcloud container / sql operations list 確認")
                    if name:  # 再列一次確認仍是同一筆唯一的新操作,避免剛好只看到別人的
                        time.sleep(OP_POLL_SECONDS)
                        try:
                            again = self._find_operation(s, svc, argv)
                        except gglib.Blocked:
                            again = ""
                        if again == name:
                            break
                        if again == "MULTI":
                            return unknown("指令已送出,但同時有多個可能的操作,無法確定是哪一個;請用 gcloud container / sql operations list 確認")
                        name = ""
                    if time.time() >= t_end:
                        break
                    time.sleep(OP_POLL_SECONDS)
            if not name:
                return unknown("指令已送出,但找不到對應的操作,無法確認是否完成;請用 gcloud container / sql operations list 確認")
            self.seen_ops = getattr(self, "seen_ops", set()) | {name}
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
                    if re.search(r"PERMISSION_DENIED|NOT_FOUND|\bHTTP(?:Error)? ?40[34]\b|\b40[34]\b(?=[: ]+(?:Forbidden|Not Found|PERMISSION|NOT_FOUND))", last_err):
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

    def _find_operation(self, s, svc, argv):
        """送出後才出現(不在送出前快照裡)的對應操作。不依賴兩邊時鐘。"""
        now = self._list_ops(s, svc, argv)
        pre = getattr(self, "pre_ops", None)
        if now is None or pre is None:
            return ""  # 送出前或現在列不出操作:無法安全比對
        cands = [n for n in now if n not in pre and n not in getattr(self, "seen_ops", set())]
        if len(cands) > 1:
            return "MULTI"  # 不猜:多筆都可能是,交給使用者確認
        return cands[0] if cands else ""

    def _list_ops(self, s, svc, argv):
        """列出這個資源可能是這類變更的操作名稱;列不出來回 None。"""
        project = _flag(argv, "--project")
        pos = [a for a in argv if not a.startswith("-")]
        target = pos[4] if len(pos) > 4 else None  # gcloud container clusters <verb> <name> / gcloud sql instances patch <name>
        kind = getattr(self, "cur_kind", "")
        nodepool = None
        if kind == "gke-nodepool-update":
            nodepool = target
        elif kind == "gke-resize":
            nodepool = _flag(argv, "--node-pool")
        if svc == "container":
            cluster = _flag(argv, "--cluster") or target  # node-pools update 用 --cluster
            # 精確的 regex 過濾(prod 不會比中 prod-2),取多一點再在本地比對
            tl = f"/clusters/{cluster}"  # 伺服器端只粗篩(不用括號等 filter 語法),精確比對在下面的 want
            q = s.gcloud(["container", "operations", "list", f"--location={_flag(argv, '--location')}", f"--filter=targetLink~{tl}",
                          "--sort-by=~startTime", "--limit=50", f"--project={project}", "--format=json", "--quiet"], mode="dryrun")
        else:
            q = s.gcloud(["sql", "operations", "list", f"--instance={target}", "--limit=50", f"--project={project}", "--format=json", "--quiet"], mode="dryrun")
        if q.returncode != 0:
            return None
        try:
            ops = json.loads(q.stdout or "[]")
        except ValueError:
            return None
        cands = []
        for o in ops if isinstance(ops, list) else []:
            if not isinstance(o, dict) or not o.get("name"):
                continue
            nm = o["name"].rsplit("/", 1)[-1]
            if svc == "container":
                link = str(o.get("targetLink") or "")
                # 叢集層級一定接受;改 node pool 時也接受那個 node pool 層級(gcloud 有些 node pool 變更走 clusters.update)
                want = r"/clusters/" + re.escape(cluster) + (r"(/nodePools/" + re.escape(nodepool) + r")?" if nodepool else "") + r"$"
                if not re.search(want, link):
                    continue
                if str(o.get("operationType") or "").upper().startswith("AUTO_"):
                    continue  # 排除 auto-repair / auto-upgrade;其他同時出現的候選會變成「多筆」→ 狀態不明,不猜
            elif str(o.get("operationType") or "").upper() != "UPDATE":
                continue  # SQL:只接受 patch(UPDATE),排除備份等其他操作
            cands.append(nm)
        return cands

    @staticmethod
    def _op_result(r, svc, st):
        err = st.get("error")
        if not err and svc == "container" and str(st.get("statusMessage") or "").strip():
            # DONE 但只有 statusMessage:不確定是警告還是失敗 → 狀態不明,交給驗證與使用者確認
            return subprocess.CompletedProcess(r.args, 124, json.dumps(st, ensure_ascii=False),
                                               "操作 DONE 但帶有 statusMessage:" + gglib._short(str(st.get("statusMessage")), 300))
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
        try:
            s.ensure_fresh()  # 帳號模式:作廢核准檔與送出前先換好 token;失敗代表指令還沒送出、核准檔也還在
        except gglib.Blocked as e:
            return self.stop("BLOCKED", cid, "送出前取得 token 失敗:" + str(e))
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
                         "rollback_warning": it.get("rollback_warning")}
        kinfo = ggchange.change_rules()["kinds"][kind]
        run_argv = argv + (["--async", "--format=json"] if kinfo.get("async") else [])
        try:
            # 帳號模式的 token 至少剩約 10 分鐘:不走 --async 的指令逾時 8 分鐘(留餘裕,避免中途過期)
            tmo = 300 if kinfo.get("async") else (480 if self.cfg.get("GG_AUTH") == "user" else 1800)
            if kinfo.get("async"):  # 送出前快照這個資源既有的操作:之後 gcloud 沒印操作時,用差集找自己的
                self.cur_kind = kind
                try:
                    pre = self._list_ops(s, kinfo["async"], argv)
                except gglib.Blocked:
                    pre = None
                self.pre_ops = set(pre) if pre is not None else None
            r = s._exec(run_argv, "change", timeout=tmo)
        except (gglib.Denied, gglib.Blocked) as e:  # 執行前被拒絕或取不到 token:雲端沒被動到
            self.inflight = None
            return self.stop("BLOCKED", cid, "執行前被拒絕:" + str(e))
        if r.returncode == 0 and kinfo.get("async"):
            self.cur_kind = kind
            r = self.wait_operation(s, kinfo["async"], r, argv)
        rec = {"id": cid, "kind": kind, "argv": it["command"], "rc": r.returncode, "dry_run": dry,
               "stderr": gglib._short(r.stderr, 800)}
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
        deadline = time.time() + (VERIFY_WAIT if kind == "gke-resize" else 0)
        while True:
            try:
                after, _, err = ggplan.snapshot(s, kind, argv, self.project, ctx_done)
            except (gglib.Blocked, gglib.Denied) as e:
                after, err = None, str(e)
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
        rec.update({"result": "已執行", "reason": "驗證符合"})
        return True


def write_log(run, plan_path, sha, approved, runner):
    lines = [f"# 變更紀錄", "", f"- 計畫:`{plan_path}`", f"- plan sha256:`{sha}`", f"- 核准:{', '.join(approved)}",
             f"- 狀態:**{runner.status}**", f"- 時間:{gglib.now_iso()}", "",
             "| C | 結果 | 原因 / 驗證 | 結束碼 | 還原指令 |", "|---|---|---|---|---|"]
    def cell(x):
        return str(x).replace("|", "\\|").replace("\r", "").replace("\n", "<br>")
    for r in runner.results:
        rb = shlex.join(r.get("rollback") or []) or r.get("rollback_note") or "-"
        warn = f"<br>⚠ {r['rollback_warning']}" if r.get("rollback_warning") else ""
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
                  + (f"\t⚠ {r['rollback_warning']}" if r.get("rollback_warning") else ""))
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
