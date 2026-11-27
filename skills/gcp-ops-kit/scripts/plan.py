#!/usr/bin/env python3
"""變更計畫產生器。

  plan.py build <run 目錄>              讀 <run>/plan.input.json,快照 + dry-run + 分類,寫 plan.json,重產報告
  plan.py sha <plan.json>               印 sha256
  plan.py show <plan.json>              印每條摘要

plan.input.json(agent 用 Write 寫,只寫這些欄位;kind / reversible / rollback / loosens 由本程式計算):
{"items": [{"id": "C1", "summary": "…", "finding": "GCS-PUB-001",
            "command": ["gcloud", "storage", "buckets", "remove-iam-policy-binding", "gs://b",
                        "--member=allUsers", "--role=roles/storage.objectViewer", "--project=p"],
            "manifest": "<kubectl apply 時的 YAML 全文;command 用 --filename=<manifest>>",
            "patch": "<kubectl patch 時的內容;command 用 --patch-file=<patch>>",
            "precondition": [{"field": "/JSON pointer", "expect": 值}],
            "expected": [{"field": "/JSON pointer", "expect": 值}],
            "impact": "無 / 重建 Pod / 短暫中斷 …"}]}
結束碼:0 全部可執行、1 有條目 BLOCKED / 不可還原 / 放寬安全(計畫仍產出)、3 BLOCKED、2 用法錯誤
"""
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import gglib  # noqa: E402
import ggchange  # noqa: E402
import ggplan  # noqa: E402

ID_RE = re.compile(r"^C[1-9][0-9]{0,2}$")


def build(run):
    run = os.path.realpath(run)
    meta = gglib.read_json(os.path.join(run, "meta.json"))
    if not meta:
        raise gglib.Blocked(f"{run} 不是 run 目錄(缺 meta.json)")
    cfg = gglib.load_config(require=True)
    if not run.startswith(os.path.realpath(cfg["GG_REPORT_DIR"]) + os.sep):
        raise gglib.Blocked("run 目錄不在 GG_REPORT_DIR 底下")
    project = meta["project"]
    inp = gglib.read_json(os.path.join(run, "plan.input.json"))
    if not inp or not isinstance(inp.get("items"), list):
        raise gglib.Blocked("缺 plan.input.json 或格式不對(要有 items 陣列)")
    ids = [it.get("id") for it in inp["items"]]
    if len(set(ids)) != len(ids) or not all(isinstance(i, str) and ID_RE.match(i) for i in ids):
        raise gglib.Blocked(f"id 要是不重複的 C<n>:{ids}")
    gglib.install_signal_handlers()
    lock = gglib.acquire_lock(cfg, project, "plan", run)
    items = []
    try:
        with gglib.Session(cfg, run, project, "dryrun") as s:
            ctx_done = set()
            for raw in inp["items"]:
                items.append(build_item(s, cfg, run, project, raw, ctx_done))
    finally:
        gglib.release_lock(cfg, project, run)
    plan = {"project": project, "source_run": run, "created": gglib.now_iso(), "sa": cfg.get("GG_SA"),
            "items": items}
    path = os.path.join(run, "plan.json")
    with open(path, "w", encoding="utf-8") as f:
        f.write(ggplan.stable_dump(plan))
    os.chmod(path, 0o600)
    sha = gglib.sha256_file(path)
    subprocess.run(["node", os.path.join(gglib.KIT, "scripts", "render.mjs"), run])
    print(f"plan={path}")
    print(f"sha256={sha}")
    for it in items:
        print(summary_line(it))
    bad = [it for it in items if it["blocked_reason"] or it["loosens_security"]]
    return 1 if bad else 0


def summary_line(it):
    st = "BLOCKED" if it["blocked_reason"] else ("可執行(放寬安全)" if it["loosens_security"] else "可執行")
    why = it["blocked_reason"] or "; ".join(it["loosens_reasons"])
    return f"{it['id']}\t{st}\t{it['kind'] or '-'}\t{it['summary']}" + (f"\t{why}" if why else "")


def build_item(s, cfg, run, project, raw, ctx_done):
    item = {k: raw.get(k) for k in ("id", "summary", "finding", "command", "manifest", "patch",
                                     "precondition", "expected", "impact")}
    item["precondition"] = item["precondition"] or []
    item["expected"] = item["expected"] or []
    item.update({"kind": None, "target": {}, "reversible": False, "rollback": None, "loosens_security": False,
                 "loosens_reasons": [], "blocked_reason": None, "auto_pre": [], "dry_run": None,
                 "dry_run_log": [], "precondition_failed_at_plan": [], "rollback_warning": None, "rollback_note": None})

    def blocked(msg):
        item["blocked_reason"] = item["blocked_reason"] or msg
        return item

    if not item["summary"] or not isinstance(item["command"], list):
        return blocked("缺 summary 或 command")
    for fld in ("precondition", "expected"):
        v = item[fld]
        def _okb(x):
            return any(isinstance(x.get(k), list) and len(x[k]) == 2 and all(isinstance(y, str) for y in x[k])
                       for k in ("binding_absent", "binding_present"))
        if not isinstance(v, list) or not all(isinstance(x, dict) and (("field" in x and isinstance(x["field"], str)) or _okb(x)) for x in v):
            return blocked(f"{fld} 要是 [{{\"field\": \"/JSON pointer\", \"expect\": 值}}] 陣列")
    for fld in ("manifest", "patch"):
        if item[fld] is not None and not isinstance(item[fld], str):
            return blocked(f"{fld} 要是字串")
    try:
        argv = ggplan.materialize(item, run)
    except gglib.Blocked as e:
        return blocked(str(e))
    except Exception as e:
        return blocked(f"寫 manifest / patch 失敗:{e}")
    shape = ggchange.classify(argv, cfg, shape_only=True)
    if shape["blocked_reason"]:
        item.update({k: shape[k] for k in ("kind", "target", "blocked_reason")})
        return item
    kind = shape["kind"]
    if argv[0] == "gcloud" and shape["target"].get("project") != project:
        return blocked(f"--project 必須是 {project}")
    if not item["expected"] and kind != "kubectl-rollout-restart":
        return blocked("缺 expected(變更後要驗證的欄位與值)")
    try:
        snap, endpoint, err = ggplan.snapshot(s, kind, argv, project, ctx_done)
    except (gglib.Blocked, gglib.Denied) as e:
        return blocked(str(e))
    if err:
        return blocked("快照失敗:" + err)
    if kind in ("kubectl-apply", "kubectl-patch"):
        if kind == "kubectl-patch" and (snap or {}).get("_absent"):
            return blocked("要 patch 的資源不存在")
        try:
            created, new_findings, log, err = ggplan.k8s_dryrun(s, kind, argv, snap)
        except gglib.Denied as e:
            return blocked(str(e))
        item["dry_run_log"] = [{"step": a, "rc": b, "out": c} for a, b, c in log]
        if err:
            return blocked(err)
        res = ggchange.classify(argv, cfg, snap, new_findings, created)
    else:
        res = ggchange.classify(argv, cfg, snap)
    for k in ("kind", "target", "reversible", "rollback", "loosens_security", "loosens_reasons",
              "blocked_reason", "auto_pre", "dry_run", "rollback_warning", "rollback_note"):
        item[k] = res[k]
    if endpoint:
        item["target"]["endpoint"] = endpoint
    item["target"]["project"] = project
    if item["rollback"]:
        item["rollback"] = [a.replace("<before/C?.json>", f"<變更 run>/before/{item['id']}.rollback.json") for a in item["rollback"]]
    item["precondition_failed_at_plan"] = ggplan.check_pre(item["precondition"] + item["auto_pre"], snap)
    if item["precondition_failed_at_plan"] and not item["blocked_reason"]:
        item["blocked_reason"] = "precondition 在計畫當下就不成立"
    snap_path = os.path.join(run, "snapshots", f"{item['id']}.json")
    gglib.write_json(snap_path, gglib.redact(snap))
    return item


def main(argv):
    if len(argv) < 2:
        gglib.die(__doc__, gglib.EXIT_USAGE)
    cmd, target = argv[0], argv[1]
    try:
        if cmd == "build":
            return build(target)
        if cmd == "sha":
            print(gglib.sha256_file(target))
            return 0
        if cmd == "show":
            for it in (gglib.read_json(target) or {}).get("items", []):
                print(summary_line(it))
            return 0
    except gglib.Blocked as e:
        print(f"BLOCKED: {e}", file=sys.stderr)
        return gglib.EXIT_BLOCKED
    except gglib.Denied as e:
        print(f"DENIED: {e}", file=sys.stderr)
        return gglib.EXIT_DENIED
    gglib.die(__doc__, gglib.EXIT_USAGE)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
