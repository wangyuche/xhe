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


class Runner:
    def __init__(self, cfg, plan, plan_path, approved):
        self.cfg, self.plan, self.plan_path, self.approved = cfg, plan, plan_path, approved
        self.project = plan["project"]
        self.results = []
        self.status = "PASS"
        self.inflight = None

    def stop(self, status, cid, msg, executed=False):
        self.results.append({"id": cid, "result": "BLOCKED" if status == "BLOCKED" else "失敗", "reason": msg})
        executed = any(str(r.get("result", "")).startswith("已執行") or r.get("rc") == 0 for r in self.results)
        # 已經有條目改了雲端:整體不能回 BLOCKED(那代表「事前檢查不過、什麼都沒改」)
        self.status = "ISSUES" if executed else status
        return False

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
        bad = ggplan.check_pre((it.get("precondition") or []) + (it.get("auto_pre") or []), snap)
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
        # 先記「執行中」:若在執行途中被中斷,紀錄仍會有這條與還原指令
        self.inflight = {"id": cid, "kind": kind, "argv": it["command"], "result": "執行中被中斷(狀態不明)",
                         "reason": "指令已送出但沒有等到結果;請先確認現況",
                         "rollback": [a.replace("<變更 run>", self.run) for a in (it.get("rollback") or [])],
                         "rollback_warning": it.get("rollback_warning")}
        try:
            r = s._exec(argv, "change", timeout=1800)
        except gglib.Denied as e:  # 第二道防線在執行前拒絕:雲端沒被動到
            self.inflight = None
            return self.stop("BLOCKED", cid, "執行前被拒絕:" + str(e))
        self.inflight = None
        rec = {"id": cid, "kind": kind, "argv": it["command"], "rc": r.returncode, "dry_run": dry,
               "stderr": gglib._short(r.stderr, 800)}
        if r.returncode != 0:
            rec["rollback"] = [a.replace("<變更 run>", self.run) for a in (it.get("rollback") or [])]
            rec.update({"result": "失敗(可能部分套用)", "reason": f"指令失敗(rc={r.returncode});請先確認現況再決定是否還原"})
            self.results.append(rec)
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
    plan_path, sha, approved_text = os.path.realpath(argv[0]), argv[2], argv[4]
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
        project = gglib.check_project(plan["project"])
        run = gglib.new_run(cfg, project, "change")
        meta = gglib.read_json(os.path.join(run, "meta.json"))
        meta.update({"plan": plan_path, "plan_sha256": sha, "approved": approved, "source_run": plan.get("source_run")})
        gglib.write_json(os.path.join(run, "meta.json"), meta)
        gglib.acquire_lock(cfg, project, "change", run)
        runner = Runner(cfg, plan, plan_path, approved)
        try:
            status = runner.execute(run)
        except (gglib.Blocked, gglib.Denied) as e:
            runner.status = "BLOCKED"
            runner.results.append({"id": "-", "result": "BLOCKED", "reason": str(e)})
            status = "BLOCKED"
        except SystemExit:
            # 被中斷(例如逾時被砍):先寫紀錄(含已執行 / 執行中條目的還原指令)再結束
            if runner.inflight:
                runner.results.append(runner.inflight)
            runner.status = "ISSUES" if runner.inflight or any(r.get("rc") == 0 for r in runner.results) else "BLOCKED"
            runner.results.append({"id": "-", "result": "中斷", "reason": "change.sh 被中斷;進行中的雲端操作可能仍在跑,請先確認現況"})
            gglib.release_lock(cfg, project, run)
            write_log(run, plan_path, sha, approved, runner)
            raise
        except Exception as e:
            runner.status = "ISSUES" if any(r.get("rc") == 0 for r in runner.results) else "BLOCKED"
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
