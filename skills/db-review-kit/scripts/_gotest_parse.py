#!/usr/bin/env python3
"""Summarise `go test -json` output (file argv[1]) into one JSON object on stdout.

Counts top-level tests and subtests separately; every SKIP gets its reason (the t.Skip message);
FAIL entries keep the last output lines; build failures count as failed packages.
"""
import json
import sys

NOISE = ("=== RUN", "=== PAUSE", "=== CONT", "=== NAME", "--- SKIP", "--- PASS", "--- FAIL")


def main(path, elapsed, go_rc=0):
    outputs = {}
    results = {}
    pkgs = {}
    raw = []
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.startswith("{"):
                if line.strip():
                    raw.append(line)
                continue
            try:
                ev = json.loads(line)
            except ValueError:
                raw.append(line)
                continue
            act = ev.get("Action")
            pkg = ev.get("Package") or (ev.get("ImportPath") or "").split(" [", 1)[0]
            test = ev.get("Test")
            if act in ("output", "build-output"):
                outputs.setdefault((pkg, test), []).append(ev.get("Output", ""))
            elif act == "build-fail":
                pkgs[pkg] = "build-fail"
            elif act in ("pass", "fail", "skip"):
                if test:
                    results[(pkg, test)] = act
                elif pkgs.get(pkg) != "build-fail":
                    pkgs[pkg] = act

    def bucket(sub):
        c = {"pass": 0, "fail": 0, "skip": 0}
        for (p, t), a in results.items():
            if ("/" in t) == sub:
                c[a] += 1
        c["total"] = c["pass"] + c["fail"] + c["skip"]
        return c

    top, subs = bucket(False), bucket(True)
    skipped, failed = [], []
    for (p, t), a in sorted(results.items()):
        lines = [l.rstrip() for l in outputs.get((p, t), [])]
        body = [l.strip() for l in lines if l.strip() and not l.strip().startswith(NOISE)]
        if a == "skip":
            skipped.append({"package": p, "test": t, "reason": " ".join(body)[:400] or "(no message)"})
        elif a == "fail":
            failed.append({"package": p, "test": t, "output": body[-15:]})
    pkg_count = {"ok": 0, "fail": 0, "no_tests": 0, "build_fail": 0}
    for p, a in pkgs.items():
        if a == "pass":
            pkg_count["ok"] += 1
        elif a == "fail":
            pkg_count["fail"] += 1
        elif a == "skip":
            pkg_count["no_tests"] += 1
        else:
            pkg_count["build_fail"] += 1
    build_errors = [p for p, a in pkgs.items() if a == "build-fail"]
    for p in build_errors:
        failed.append({"package": p, "test": "(build)", "output": [l.rstrip() for l in outputs.get((p, None), [])][-15:]})
    # A package can fail without a failing test (TestMain exit, timeout panic, vet error): still a failure.
    fail = bool(top["fail"] or subs["fail"] or pkg_count["fail"] or pkg_count["build_fail"])
    gaps = []
    if top["total"] == 0:
        gaps.append("no tests ran")
    if top["skip"] or subs["skip"]:
        gaps.append("%d skipped" % (top["skip"] + subs["skip"]))
    if go_rc != 0 and not fail:
        # go exited non-zero without a failing test event (build/setup error printed as plain text, panic, timeout)
        fail = True
        failed.append({"package": "(go)", "test": "(exit %d)" % go_rc, "output": raw[-15:]})
    status = "FAIL" if fail else ("GAP" if gaps else "PASS")
    out = {
        "status": status, "tests": top, "subtests": subs, "packages": pkg_count,
        "skipped": skipped, "failed": failed, "gaps": gaps, "elapsed_s": elapsed,
        "non_json_output": raw[-20:],
    }
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], int(sys.argv[2]) if len(sys.argv) > 2 else 0, int(sys.argv[3]) if len(sys.argv) > 3 else 0))
