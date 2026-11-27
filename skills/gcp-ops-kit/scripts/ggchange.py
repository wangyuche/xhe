"""變更分類(plan.py 與 change.sh 共用,不可單獨執行)。

classify(argv, cfg, snapshot) → dict:
  kind, target, reversible, rollback, loosens_security, loosens_reasons, blocked_reason, auto_pre, dry_run
規則由 rules/allow_change.json 驅動;agent 給的 kind / reversible / rollback / loosens 一律忽略。
"""
import ipaddress
import json
import os
import re

import gglib

CFG = None


def change_rules():
    global CFG
    if CFG is None:
        with open(os.path.join(gglib.RULES_DIR, "allow_change.json"), encoding="utf-8") as f:
            CFG = json.load(f)
    return CFG


def _split_flags(args):
    """回傳 (positional, flags dict 保序)。flag 只接受 --x=v 或 --x(布林)。"""
    pos, flags = [], {}
    for a in args:
        if a.startswith("--"):
            if "=" in a:
                k, v = a.split("=", 1)
            else:
                k, v = a, True
            if k in flags:
                raise ValueError(f"旗標重複:{k}")
            flags[k] = v
        elif a.startswith("-") and len(a) > 1:
            raise ValueError(f"只接受 --長旗標=值 的寫法:{a}")
        else:
            pos.append(a)
    return pos, flags


def _ranges(v):
    return [x.strip() for x in str(v).split(",") if x.strip()]


def _net(x):
    try:
        return ipaddress.ip_network(x, strict=False)
    except ValueError:
        return None


def _subset_cidrs(new, old):
    try:
        oldn = [ipaddress.ip_network(o, strict=False) for o in old]
        for n in new:
            nn = ipaddress.ip_network(n, strict=False)
            if not any(nn.version == o.version and nn.subnet_of(o) for o in oldn):
                return False
        return True
    except ValueError:
        return False


def _fw_rules_from_snapshot(snap):
    out = []
    for a in snap.get("allowed") or []:
        proto = a.get("IPProtocol")
        ports = a.get("ports") or []
        if ports:
            out += [f"{proto}:{p}" for p in ports]
        else:
            out.append(proto)
    return out


PORTLESS = {"icmp", "esp", "ah", "ipip", "gre", "icmpv6", "58", "1", "50", "51", "4", "47"}


def _port_all(rule):
    if rule in ("all",):
        return True
    if rule.lower() in PORTLESS:
        return False
    m = re.fullmatch(r"(tcp|udp|sctp|all|\d+)(?::(\d+)(?:-(\d+))?)?", rule)
    if not m:
        return True  # 看不懂的一律當成全開
    proto, a, b = m.groups()
    if proto == "all":
        return True
    if a is None:
        return True  # tcp 沒寫埠 = 全部埠
    lo, hi = int(a), int(b or a)
    return hi - lo + 1 > 1000  # 一次開超過 1000 個埠視同全開(例 tcp:2-65535)


def _port_total(rules):
    """每個協定把埠範圍合併後的總埠數(取最大的協定)。"""
    per = {}
    for r in rules:
        m = re.fullmatch(r"(\w+):(\d+)(?:-(\d+))?", r)
        if not m:
            continue
        p, a, b = m.groups()
        per.setdefault(PROTO_NUM.get(p, p), []).append((int(a), int(b or a)))
    best = 0
    for iv in per.values():
        iv.sort()
        tot, cur = 0, None
        for lo, hi in iv:
            if cur and lo <= cur[1] + 1:
                cur = (cur[0], max(cur[1], hi))
            else:
                if cur:
                    tot += cur[1] - cur[0] + 1
                cur = (lo, hi)
        if cur:
            tot += cur[1] - cur[0] + 1
        best = max(best, tot)
    return best


def _rules_subset(new, old):
    def expand(r):
        m = re.fullmatch(r"(\w+)(?::(\d+)(?:-(\d+))?)?", r)
        if not m:
            return None
        p, a, b = m.groups()
        p = PROTO_NUM.get(p, p)
        return (p, int(a) if a else 0, int(b or a) if a else 65535)
    olds = [expand(o) for o in old]
    for n in new:
        e = expand(n)
        if e is None:
            return False
        if not any(o and (o[0] == "all" or (o[0] == e[0] and o[1] <= e[1] and o[2] >= e[2])) for o in olds):
            return False
    return True


NET_FLAGS = {"--source-ranges", "--master-authorized-networks", "--authorized-networks", "--destination-ranges"}
PROTO_NUM = {"6": "tcp", "17": "udp", "132": "sctp", "1": "icmp", "50": "esp", "51": "ah"}

POD_SECURITY_ORDER = {"privileged": 0, "baseline": 1, "restricted": 2}


def common_forbidden(argv, cfg):
    # 只看指令詞與旗標名稱,不看旗標值(例 --description=do not delete 不算 delete)
    text = " ".join(a.split("=", 1)[0] if a.startswith("--") else a for a in argv)
    rules = change_rules()
    for tok in rules["forbidden_tokens"]:
        if re.search(tok, text):
            return f"一律禁止(命中 {tok!r})"
    if ("--member=allUsers" in argv or "--member=allAuthenticatedUsers" in argv) and "add-iam-policy-binding" in argv:
        return "一律禁止:新增公開成員 allUsers / allAuthenticatedUsers"
    nets4, nets6 = [], []
    for a in argv:
        for part in re.split(r"[=,;]", a):
            part = part.strip()
            if "/" not in part or not re.fullmatch(r"[0-9A-Fa-f.:]+/\d{1,3}", part):
                continue
            try:
                n = ipaddress.ip_network(part, strict=False)
            except ValueError:
                return f"一律禁止:看不懂的網段 {part}"
            if n.prefixlen == 0:
                return "一律禁止:來源 / 授權網路含 0.0.0.0/0 或 ::/0(任何寫法)"
            (nets4 if n.version == 4 else nets6).append(n)
    for nets in (nets4, nets6):
        if any(c.prefixlen == 0 for c in ipaddress.collapse_addresses(nets)):
            return "一律禁止:多個網段合起來涵蓋整個網際網路"
    sa = cfg.get("GG_SA")
    if sa and any(sa.lower() in a.lower() for a in argv):  # 看原始參數(含旗標值),SA 一定在 --member= 裡
        return f"一律禁止:動到 gcp-guardian 自己的 SA({sa})"
    return None


def classify(argv, cfg, snapshot=None, manifest_findings=None, diff_created=None, shape_only=False):
    """snapshot:變更前快照(dict,依 kind 不同)。manifest_findings:apply / patch dry-run 結果跑 k8s_rules 的 findings。
    diff_created:kubectl diff 是否出現新建資源。"""
    res = {"kind": None, "target": {}, "reversible": False, "rollback": None, "rollback_warning": None, "rollback_note": None,
           "loosens_security": False, "loosens_reasons": [], "blocked_reason": None,
           "auto_pre": [], "dry_run": None}

    def block(msg):
        res["blocked_reason"] = res["blocked_reason"] or msg
        return res

    if not isinstance(argv, list) or not argv or not all(isinstance(a, str) for a in argv):
        return block("command 要是字串陣列")
    if any(re.search(r"[\n\r\x00]", a) for a in argv):
        return block("參數含換行或控制字元")
    f = common_forbidden(argv, cfg)
    if f:
        return block(f)
    rules = change_rules()
    kind = None
    for name, k in rules["kinds"].items():
        pre = k["prefix"]
        if argv[:len(pre)] == pre:
            kind = name
            break
        if pre[0] == "kubectl" and argv and argv[0] == "kubectl" and len(argv) > 1 \
                and argv[1].startswith("--context=") and argv[2:2 + len(pre) - 1] == pre[1:]:
            kind = name
            break
    if argv[0] == "kubectl" and not (len(argv) > 1 and argv[1].startswith("--context=")):
        return block("kubectl 的第二個參數必須是 --context=gke_<專案>_<位置>_<叢集>")
    if not kind:
        return block("不在變更允許清單(請使用者自己執行)")
    res["kind"] = kind
    k = rules["kinds"][kind]
    snap = snapshot or {}
    try:
        if argv[0] == "kubectl":
            ctx = argv[1][len("--context="):]
            pos, flags = _split_flags(argv[2 + len(k["prefix"]) - 1:])
            res["target"]["context"] = ctx
        else:
            pos, flags = _split_flags(argv[len(k["prefix"]):])
    except ValueError as e:
        return block(str(e))
    if len(pos) != k.get("positional", 1):
        return block(f"{kind} 要 {k.get('positional', 1)} 個位置參數,收到 {pos}")
    for req in k.get("required_flags", []):
        if req not in flags:
            return block(f"{kind} 缺必要旗標 {req}")
    allowed = set(k.get("required_flags", [])) | set(k.get("flags", {}).keys()) | ({"--quiet"} if argv[0] == "gcloud" else set())
    for fl in flags:
        if fl not in allowed:
            return block(f"{kind} 不允許旗標 {fl}")
    bools = set(rules.get("bool_flags", []))
    for fl, val in flags.items():
        if val is True and fl not in bools:
            return block(f"{fl} 要帶值(寫成 {fl}=值)")
        if val is not True and fl in bools:
            return block(f"{fl} 是布林旗標,不可帶值")
    for fl, need in rules.get("requires", {}).items():
        if fl in flags and need not in flags:
            return block(f"{fl} 要同時帶 {need}(gcloud 規定)")
    for fl, val in flags.items():
        only = (k.get("flags", {}).get(fl) or {}).get("only_values")
        if only is not None and str(val) not in only:
            return block(f"{fl} 只允許 {only}")
    pre = _resource_precheck(kind, pos, flags)
    if pre:
        return block(pre)
    if argv[0] == "gcloud":
        res["target"]["project"] = flags.get("--project")
    res["target"]["resource"] = pos[0] if pos else None
    for key in ("--location", "--cluster", "-n", "--namespace"):
        if key in flags:
            res["target"][key.lstrip("-")] = flags[key]

    if shape_only:
        return res
    handler = globals().get("_k_" + kind.replace("-", "_"))
    rollback_args, reasons, why_irrev = handler(pos, flags, snap, res, k, cfg, manifest_findings, diff_created)
    if res["blocked_reason"]:
        return res
    res["loosens_reasons"] = reasons
    res["loosens_security"] = bool(reasons)
    if rollback_args and not res.get("rollback_warning"):
        rb_nets = []
        for a in rollback_args:
            if isinstance(a, str) and a.split("=")[0] in NET_FLAGS and "=" in a:
                for part in re.split(r"[,;]", a.split("=", 1)[1]):
                    try:
                        rb_nets.append(ipaddress.ip_network(part.strip(), strict=False))
                    except ValueError:
                        pass
        if rb_nets and any(c.prefixlen == 0 for v in (4, 6)
                           for c in ipaddress.collapse_addresses([n for n in rb_nets if n.version == v])):
            res["rollback_warning"] = "這條還原會重新對整個網際網路開放(0.0.0.0/0);除非確定要回復,否則不要執行"
        elif rb_nets:
            new_nets = []
            for a in argv:
                if a.split("=")[0] in NET_FLAGS and "=" in a:
                    new_nets += [x for x in _ranges(a.split("=", 1)[1]) if "/" in x]
            if new_nets and not _subset_cidrs([str(n) for n in rb_nets], new_nets):
                res["rollback_warning"] = "這條還原會把網段放寬回變更前的範圍,執行前請確認"
    if rollback_args and not res.get("rollback_warning") and kind == "firewall-update":
        rbf = {a.split("=", 1)[0]: a.split("=", 1)[1] for a in rollback_args if isinstance(a, str) and a.startswith("--") and "=" in a}
        if "--rules" in rbf and "--rules" in flags:
            old_rules = _ranges(rbf["--rules"])
            if any(_port_all(r) for r in old_rules) or not _rules_subset(old_rules, _ranges(flags["--rules"])):
                res["rollback_warning"] = "這條還原會把協定 / 埠放寬回變更前的範圍(可能是全部),執行前請確認"
        if "--target-tags" in flags:
            old_t = set(_ranges(rbf.get("--target-tags", "")))
            new_t = set(_ranges(flags["--target-tags"])) if flags["--target-tags"] is not True else set()
            if (not old_t and new_t) or (new_t and not old_t <= new_t):
                res["rollback_warning"] = "這條還原會擴大防火牆套用對象(target-tags 清空或變多),執行前請確認"
        if "--priority" in rbf and "--priority" in flags:
            try:
                if int(rbf["--priority"]) < int(flags["--priority"]):
                    res["rollback_warning"] = "這條還原會把 allow 規則調回較高優先序,執行前請確認"
            except ValueError:
                pass
    if rollback_args and not res.get("rollback_warning"):
        rl = change_rules().get("rollback_loosening_flags", {})
        for a in rollback_args:
            if not isinstance(a, str) or not a.startswith("--"):
                continue
            name, _, val = a.partition("=")
            rule = k.get("flags", {}).get(name, {})
            if name in rl:
                res["rollback_warning"] = rl[name] + ",執行前請確認"
                break
            if val and val in (rule.get("loosens_values") or {}):
                res["rollback_warning"] = f"還原會放寬安全:{rule['loosens_values'][val]},執行前請確認"
                break
    loosen_flags = {f for f, r in k.get("flags", {}).items() if r.get("loosens")}
    if rollback_args and not res.get("rollback_warning") and any(a.split("=")[0] in loosen_flags for a in rollback_args if isinstance(a, str)):
        res["rollback_warning"] = "這條還原會放寬安全設定(回到變更前較寬鬆的狀態),執行前請確認"
    if why_irrev:
        res["reversible"] = False
        res["rollback"] = None
        res["blocked_reason"] = f"不可還原:{why_irrev}(請使用者自己執行)"
    else:
        res["reversible"] = True
        res["rollback"] = rollback_args if rollback_args else None
    res["dry_run"] = k.get("dry_run")
    return res


def _resource_precheck(kind, pos, flags=None):
    """快照之前就要檢查的資源種類(避免對 Secret 等資源做快照 / dry-run)與系統 namespace。"""
    rules = change_rules()
    ns = (flags or {}).get("--namespace")
    if kind == "kubectl-label-namespace":
        ns = pos[0]
    if isinstance(ns, str) and re.match(rules["system_namespaces"], ns):
        return f"不允許改系統 namespace {ns}"
    if kind == "kubectl-patch":
        if pos[0] in rules["k8s_forbidden_kinds"] or pos[0] not in rules["k8s_patch_kinds"]:
            return f"不允許 patch 這種資源:{pos[0]}(只接受小寫:{', '.join(rules['k8s_patch_kinds'])})"
        if not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", pos[1]):
            return f"資源名稱格式不對:{pos[1]}"
    if kind == "kubectl-scale" and not re.fullmatch(r"(deployment|statefulset|replicaset)/[a-z0-9][a-z0-9.-]{0,252}", pos[0]):
        return "scale 只接受 deployment|statefulset|replicaset/<名稱>"
    if kind == "kubectl-rollout-restart" and not re.fullmatch(r"(deployment|statefulset|daemonset)/[a-z0-9][a-z0-9.-]{0,252}", pos[0]):
        return "rollout restart 只接受 deployment|statefulset|daemonset/<名稱>"
    if kind == "kubectl-label-namespace" and not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", pos[0]):
        return f"namespace 名稱格式不對:{pos[0]}"
    return None


# ---------------------------------------------------------------- 各 kind

def _flag_rollback(prefix_argv, pos, flags, snap, res, k):
    """依 inverse / restore 表產生還原旗標。回傳 (argv 或 None, 不可還原原因)。"""
    out = list(prefix_argv) + list(pos)
    for req in k.get("required_flags", []):
        out.append(f"{req}={flags[req]}" if flags[req] is not True else req)
    spec = k.get("flags", {})
    changed = False
    for fl, val in flags.items():
        if fl in k.get("required_flags", []) or fl == "--quiet":
            continue
        rule = spec.get(fl, {})
        if "inverse" in rule:
            if "state" not in rule:
                return None, f"{fl} 缺變更前狀態欄位,無法確認還原"
            cur = gglib.ptr_get(snap, rule["state"])
            if cur is None and rule.get("state_required"):
                return None, f"{fl}:快照沒有 {rule['state']},無法確認變更前狀態"
            now_on = _as_bool(cur)
            want = rule["target"]
            want_on = bool(want) if want != "nonempty" else True
            if now_on == want_on and any(c in flags for c in rule.get("companion_for", [])):
                # 已啟用、只是 gcloud 要求同時帶這個旗標:還原時保留它
                res["auto_pre"].append({"field": rule["state"], "expect": cur})
                out.append(fl)
                continue
            if now_on == want_on:
                return None, f"{fl}:變更前已是目標狀態({rule['state']}={cur!r}),不需變更;還原會反向改掉原設定"
            res["auto_pre"].append({"field": rule["state"], "expect": cur})
            out.append(rule["inverse"])
            for rw in rule.get("restore_with", []):
                v = raw_v = gglib.ptr_get(snap, rw["from"])
                if v is None and "default" in rw:
                    v = rw["default"]
                if rw.get("format") == "join":
                    vals = [str(i.get(rw["item_key"]) if rw.get("item_key") else i) for i in (v or [])]
                    if vals:
                        out.append(f"{rw['flag']}={','.join(vals)}")
                    elif not rw.get("optional"):
                        return None, f"{fl}:快照沒有 {rw['from']},還原無法帶回原值"
                elif v is None:
                    return None, f"{fl}:快照沒有 {rw['from']},還原無法帶回原值"
                else:
                    out.append(f"{rw['flag']}={v}")
                res["auto_pre"].append({"field": rw["from"], "expect": raw_v})
            changed = True
        elif "restore" in rule:
            if rule.get("skip_if_off") and not _as_bool(gglib.ptr_get(snap, rule["skip_if_off"])):
                # 功能原本關閉:還原時關掉功能即可(由陪同旗標的反向旗標處理),不需要舊值
                res["auto_pre"].append({"field": rule["skip_if_off"], "expect": gglib.ptr_get(snap, rule["skip_if_off"])})
                changed = True
                continue
            raw = gglib.ptr_get(snap, rule["restore"])  # precondition 用快照原值(可能是 None)
            cur = raw
            if cur is None and "default" in rule:
                cur = rule["default"]  # GKE API 省略 0 / 預設值的欄位:還原指令用預設值
            fmt = rule.get("format", "scalar")
            if cur is None and not rule.get("empty_ok") and not rule.get("state_required") and fmt != "join":
                return None, f"快照沒有 {rule['restore']},無法產生 {fl} 的還原值"
            if cur is None and not rule.get("empty_ok") and not rule.get("clear_flag"):
                return None, f"快照沒有 {rule['restore']},無法產生 {fl} 的還原值"
            if fmt == "join":
                key = rule.get("item_key")
                items = cur or []
                vals = [str(i.get(key) if key else i) for i in items]
                if not vals:
                    if rule.get("clear_flag"):
                        out.append(rule["clear_flag"])
                        res["auto_pre"].append({"field": rule["restore"], "expect": cur})
                        changed = True
                        continue
                    return None, f"{fl} 原本為空,無法還原"
                out.append(f"{fl}={','.join(vals)}")
            elif fmt == "fw_rules":
                out.append(f"{fl}={','.join(_fw_rules_from_snapshot(snap))}")
            elif fmt == "bool_flag":
                out.append(rule["true_flag"] if cur else rule["false_flag"])
            elif fmt == "per_zone":
                out.append(f"{fl}={cur}")
            else:
                out.append(f"{fl}={'' if cur is None else cur}")
            res["auto_pre"].append({"field": rule["restore"], "expect": raw})
            changed = True
        else:
            return None, f"{fl} 沒有還原範本"
    if not changed:
        return None, "沒有任何變更旗標"
    dedup = []
    for a in out:
        if a not in dedup:
            dedup.append(a)
    dedup.append("--quiet")
    return dedup, None


def _as_bool(v):
    if isinstance(v, str):
        return v.strip().lower() in ("true", "enforced", "1", "yes", "on") or (v != "" and v.lower() not in ("false", "inherited", "unspecified", "0", "no", "off"))
    return bool(v)


def _loosen_by_table(flags, k):
    reasons = []
    for fl, val in flags.items():
        rule = k.get("flags", {}).get(fl, {})
        if rule.get("loosens"):
            reasons.append(rule["loosens"])
        if "loosens_values" in rule and str(val) in rule["loosens_values"]:
            reasons.append(rule["loosens_values"][str(val)])
    return reasons


def _k_gke_cluster_update(pos, flags, snap, res, k, cfg, *_):
    reasons = _loosen_by_table(flags, k)
    if "--master-authorized-networks" in flags:
        man = snap.get("masterAuthorizedNetworksConfig") or {}
        if not man.get("cidrBlocks") and man.get("enabled"):
            return None, reasons, "授權網路原本已啟用且清單為空,沒有不放寬的還原寫法"
    if "--master-authorized-networks" in flags and (snap.get("masterAuthorizedNetworksConfig") or {}).get("enabled"):
        # 原本未啟用 = 控制平面對所有來源開放;加上任何網段都是收緊
        old = [c.get("cidrBlock") for c in (gglib.ptr_get(snap, "/masterAuthorizedNetworksConfig/cidrBlocks") or [])]
        if not _subset_cidrs(_ranges(flags["--master-authorized-networks"]), old):
            reasons.append("放寬控制平面授權網路(新網段不在原網段內)")
    rb, why = _flag_rollback(k["prefix"], pos, flags, snap, res, k)
    return rb, reasons, why


def _k_gke_nodepool_update(pos, flags, snap, res, k, cfg, *_):
    reasons = _loosen_by_table(flags, k)
    rb, why = _flag_rollback(k["prefix"], pos, flags, snap, res, k)
    return rb, reasons, why


def _k_gke_resize(pos, flags, snap, res, k, cfg, *_):
    try:
        n = int(flags["--num-nodes"])
    except (ValueError, TypeError):
        res["blocked_reason"] = "--num-nodes 要是整數"
        return None, [], None
    if n <= 0:
        res["blocked_reason"] = "一律禁止:node pool 縮到 0"
        return None, [], None
    if (gglib.ptr_get(snap, "/nodepool/autoscaling/enabled")):
        res["blocked_reason"] = "這個 node pool 已啟用 autoscaling,resize 會被 autoscaler 蓋掉;改用 node-pools update --min-nodes / --max-nodes"
        return None, [], None
    cur = snap.get("node_count_per_zone")
    if not isinstance(cur, int) or cur <= 0:
        return None, [], "快照取不到目前每區節點數"
    res["auto_pre"].append({"field": "/node_count_per_zone", "expect": cur})
    rb = ["gcloud", "container", "clusters", "resize", pos[0], f"--node-pool={flags['--node-pool']}",
          f"--num-nodes={cur}", f"--location={flags['--location']}", f"--project={flags['--project']}", "--quiet"]
    return rb, [], None


def _k_firewall_update(pos, flags, snap, res, k, cfg, *_):
    if snap.get("denied") or not snap.get("allowed") or snap.get("direction", "INGRESS") != "INGRESS":
        res["blocked_reason"] = "只允許修改 INGRESS 的 allow 規則;deny / egress 規則請使用者自己改"
        return None, [], None
    reasons = _loosen_by_table(flags, k)
    src = snap.get("sourceRanges") or []
    public = (not src and not snap.get("sourceTags") and not snap.get("sourceServiceAccounts")) or \
        any(c.prefixlen == 0 for v in (4, 6) for c in ipaddress.collapse_addresses(
            [n for n in (_net(x) for x in src) if n is not None and n.version == v]))
    if public and "--source-ranges" not in flags:
        widen = ("--no-disabled" in flags
                 or any(key in flags and not _rules_subset(_ranges(flags[key]), _fw_rules_from_snapshot(snap)) for key in ("--rules", "--allow"))
                 or ("--target-tags" in flags and snap.get("targetTags") and
                     (not _ranges(flags["--target-tags"]) or not set(_ranges(flags["--target-tags"])) <= set(snap.get("targetTags")))))
        if widen:
            res["blocked_reason"] = "一律禁止:這條規則對整個網際網路開放,不可再擴大埠 / 對象或重新啟用(請先收緊來源)"
            return None, [], None
    for key in ("--rules", "--allow"):
        if key in flags:
            for r in _ranges(flags[key]):
                if _port_all(r):
                    res["blocked_reason"] = f"一律禁止:防火牆 {key} 含全部協定 / 全部埠({r})"
                    return None, [], None
            total = _port_total(_ranges(flags[key]))
            if total > 1000:
                res["blocked_reason"] = f"一律禁止:防火牆 {key} 合計開放 {total} 個埠(超過 1000 視同全開)"
                return None, [], None
            if not _rules_subset(_ranges(flags[key]), _fw_rules_from_snapshot(snap)):
                reasons.append("放寬防火牆協定 / 埠")
    if "--source-ranges" in flags and not _ranges(flags["--source-ranges"]) and flags["--source-ranges"] is not True:
        res["blocked_reason"] = "一律禁止:清空 --source-ranges(沒有來源的 ingress 規則等於 0.0.0.0/0)"
        return None, [], None
    if "--source-ranges" in flags and flags["--source-ranges"] is True:
        res["blocked_reason"] = "--source-ranges 要有值"
        return None, [], None
    if "--source-ranges" in flags and not _subset_cidrs(_ranges(flags["--source-ranges"]), snap.get("sourceRanges") or []):
        reasons.append("放寬防火牆來源網段")
    if "--target-tags" in flags:
        new_t, old_t = set(_ranges(flags["--target-tags"])), set(snap.get("targetTags") or [])
        if (not new_t and old_t) or (old_t and not new_t <= old_t):
            reasons.append("放寬防火牆套用對象(target-tags 清空或新增)")
    if "--priority" in flags:
        try:
            if int(flags["--priority"]) < int(snap.get("priority", 1000)):
                reasons.append("提高 allow 規則優先序(可能蓋過 deny 規則)")
        except ValueError:
            res["blocked_reason"] = "--priority 要是整數"
            return None, [], None
    name = pos[0]
    IAP = ipaddress.ip_network("35.235.240.0/20")

    def _covers_iap(ranges):
        for x in ranges or []:
            try:
                n = ipaddress.ip_network(x, strict=False)
                if n.version == 4 and n.overlaps(IAP):
                    return True
            except ValueError:
                pass
        return False
    iap = _covers_iap(snap.get("sourceRanges"))
    if "--disabled" in flags and (name.startswith("gke-") or iap):
        res["blocked_reason"] = "一律禁止:停用 GKE 控制平面 / IAP 的防火牆規則"
        return None, [], None
    if "--source-ranges" in flags and iap and not _covers_iap(_ranges(flags["--source-ranges"])):
        res["blocked_reason"] = "一律禁止:移除 IAP 來源 35.235.240.0/20"
        return None, [], None
    rb, why = _flag_rollback(k["prefix"], pos, flags, snap, res, k)
    return rb, reasons, why


def _k_bucket_update(pos, flags, snap, res, k, cfg, *_):
    reasons = _loosen_by_table(flags, k)
    rb, why = _flag_rollback(k["prefix"], pos, flags, snap, res, k)
    return rb, reasons, why


def _iam_common(pos, flags, res, cfg, adding):
    member, role = flags.get("--member"), flags.get("--role")
    mtype, _, ident = (member or "").partition(":")
    if mtype in ("user", "serviceAccount", "group", "domain") and ident != ident.lower():
        res["blocked_reason"] = "--member 請用小寫(GCP 會把 email 轉成小寫,大小寫不同會讓還原比對錯誤)"
        return None
    if role == "roles/owner":
        res["blocked_reason"] = "一律禁止:新增 / 移除 roles/owner"
        return None
    if member in ("allUsers", "allAuthenticatedUsers"):
        if adding:
            res["blocked_reason"] = "一律禁止:新增公開成員 allUsers / allAuthenticatedUsers"
            return None
    elif not re.fullmatch(r"(user|serviceAccount|group|domain|principal|principalSet):[^ ,]+", member or ""):
        res["blocked_reason"] = f"--member 格式不對:{member}"
        return None
    if not re.fullmatch(r"(roles|projects/[a-z0-9-]+/roles|organizations/\d+/roles)/[A-Za-z0-9_.]+", role or ""):
        res["blocked_reason"] = f"--role 格式不對:{role}"
        return None
    reasons = []
    if adding:
        hi = change_rules()["high_privilege_roles"]
        low = role in ("roles/viewer", "roles/browser") or re.fullmatch(r"roles/[A-Za-z0-9]+\.(viewer|reader|[A-Za-z]*Viewer|[A-Za-z]*Reader)", role)
        if role in hi or re.search(r"(?i)admin$", role):
            reasons.append(f"新增高權角色 {role} 給 {member}")
        elif not low:
            reasons.append(f"新增非唯讀角色 {role} 給 {member}(自訂角色或寫入權限,請確認內容)")
    return reasons


def _k_project_iam_add(pos, flags, snap, res, k, cfg, *_):
    reasons = _iam_common(pos, flags, res, cfg, True)
    if reasons is None:
        return None, [], None
    if pos[0] != flags.get("--project"):
        res["blocked_reason"] = "位置參數的專案要和 --project 相同"
        return None, [], None
    rb = ["gcloud", "projects", "remove-iam-policy-binding", pos[0], f"--member={flags['--member']}",
          f"--role={flags['--role']}", f"--project={flags['--project']}", "--condition=None", "--quiet"]
    if _has_binding(snap, flags["--member"], flags["--role"]):
        return None, reasons, "綁定原本就存在(還原會移除原有綁定)"
    res["auto_pre"].append({"binding_absent": [flags["--member"], flags["--role"]]})
    return rb, reasons, None


def _k_project_iam_remove(pos, flags, snap, res, k, cfg, *_):
    reasons = _iam_common(pos, flags, res, cfg, False)
    if reasons is None:
        return None, [], None
    if pos[0] != flags.get("--project"):
        res["blocked_reason"] = "位置參數的專案要和 --project 相同"
        return None, [], None
    if flags.get("--member") in ("allUsers", "allAuthenticatedUsers"):
        res["rollback_warning"] = PUBLIC_WARN
    rb = ["gcloud", "projects", "add-iam-policy-binding", pos[0], f"--member={flags['--member']}",
          f"--role={flags['--role']}", f"--project={flags['--project']}", "--condition=None", "--quiet"]
    res["auto_pre"].append({"binding_present": [flags["--member"], flags["--role"]]})
    return rb, [], None


PUBLIC_WARN = "這條還原會重新公開資料(加回 allUsers / allAuthenticatedUsers);除非確定要回復公開,否則不要執行"


def _k_bucket_iam_remove(pos, flags, snap, res, k, cfg, *_):
    reasons = _iam_common(pos, flags, res, cfg, False)
    if reasons is None:
        return None, [], None
    if flags.get("--member") in ("allUsers", "allAuthenticatedUsers"):
        res["rollback_warning"] = PUBLIC_WARN
    # --condition=None 只移除無條件綁定;帶條件的同名綁定不受影響,還原也只加回無條件那條
    rb = ["gcloud", "storage", "buckets", "add-iam-policy-binding", pos[0], f"--member={flags['--member']}",
          f"--role={flags['--role']}", f"--project={flags['--project']}", "--condition=None", "--quiet"]
    res["auto_pre"].append({"binding_present": [flags["--member"], flags["--role"]]})
    return rb, [], None


def _has_binding(policy, member, role):
    """只看無條件的綁定(--condition=None 的增減對象)。"""
    for b in (policy or {}).get("bindings") or []:
        if b.get("role") == role and member in (b.get("members") or []) and not b.get("condition"):
            return True
    return False


SSL_ORDER = {"ALLOW_UNENCRYPTED_AND_ENCRYPTED": 0, "ENCRYPTED_ONLY": 1, "TRUSTED_CLIENT_CERTIFICATE_REQUIRED": 2}


def _k_sql_patch(pos, flags, snap, res, k, cfg, *_):
    reasons = _loosen_by_table(flags, k)
    if "--ssl-mode" in flags:
        old = gglib.ptr_get(snap, "/settings/ipConfiguration/sslMode")
        new = str(flags["--ssl-mode"])
        if new not in SSL_ORDER:
            res["blocked_reason"] = f"--ssl-mode 不認得:{new}"
            return None, [], None
        if old in SSL_ORDER and SSL_ORDER[new] < SSL_ORDER[old] and new != "ALLOW_UNENCRYPTED_AND_ENCRYPTED":
            reasons.append(f"SSL 由 {old} 降為 {new}")
    if "--authorized-networks" in flags:
        old = [n.get("value") for n in (gglib.ptr_get(snap, "/settings/ipConfiguration/authorizedNetworks") or [])]
        if not _subset_cidrs(_ranges(flags["--authorized-networks"]), old):
            reasons.append("放寬 Cloud SQL 授權網路")
    rb, why = _flag_rollback(k["prefix"], pos, flags, snap, res, k)
    return rb, reasons, why


def _k8s_manifest_checks(res, manifest_findings, diff_created):
    reasons = []
    if diff_created is None:
        return None, "尚未取得 kubectl diff 結果(計畫階段要先 dry-run)"
    if diff_created:
        return None, "kubectl diff 顯示會新建資源,還原只能刪除(刪除一律禁止)"
    for fd in manifest_findings or []:
        if fd.get("severity") in ("嚴重", "高"):
            res["blocked_reason"] = f"套用後會產生{fd['severity']}問題 {fd['rule_id']}:{fd['title']}"
            return None, None
        if fd.get("severity") == "中":
            reasons.append(f"套用後有中度問題 {fd['rule_id']}:{fd['title']}")
    return reasons, None


def _k_kubectl_apply(pos, flags, snap, res, k, cfg, mf, dc):
    reasons, why = _k8s_manifest_checks(res, mf, dc)
    if res["blocked_reason"]:
        return None, [], None
    if why:
        return None, reasons or [], why
    return ["kubectl", f"--context={res['target']['context']}", "replace", "-f", "<before/C?.json>"], reasons, None


def _k_kubectl_patch(pos, flags, snap, res, k, cfg, mf, dc):
    if pos[0] not in change_rules()["k8s_patch_kinds"]:
        res["blocked_reason"] = f"不允許 patch 這種資源:{pos[0]}"
        return None, [], None
    reasons, why = _k8s_manifest_checks(res, mf, False if dc is None else dc)
    if res["blocked_reason"]:
        return None, [], None
    return ["kubectl", f"--context={res['target']['context']}", "replace", "-f", "<before/C?.json>"], reasons or [], why


def _k_kubectl_scale(pos, flags, snap, res, k, cfg, *_):
    if not re.fullmatch(r"(deployment|statefulset|replicaset)/[a-z0-9.-]+", pos[0]):
        res["blocked_reason"] = "scale 只接受 deployment|statefulset|replicaset/<名稱>"
        return None, [], None
    try:
        n = int(flags["--replicas"])
    except (ValueError, TypeError):
        res["blocked_reason"] = "--replicas 要是整數"
        return None, [], None
    if n <= 0:
        res["blocked_reason"] = "一律禁止:縮到 0(會停止服務,請使用者自己執行)"
        return None, [], None
    cur = gglib.ptr_get(snap, "/spec/replicas")
    if cur is None:
        return None, [], "快照沒有 /spec/replicas"
    res["auto_pre"].append({"field": "/spec/replicas", "expect": cur})
    return ["kubectl", f"--context={res['target']['context']}", "scale", pos[0],
            f"--namespace={flags['--namespace']}", f"--replicas={cur}"], [], None


def _k_kubectl_rollout_restart(pos, flags, snap, res, k, cfg, *_):
    if not re.fullmatch(r"(deployment|statefulset|daemonset)/[a-z0-9.-]+", pos[0]):
        res["blocked_reason"] = "rollout restart 只接受 deployment|statefulset|daemonset/<名稱>"
        return None, [], None
    res["rollback_note"] = "不需還原:只重啟 Pod"
    return None, [], None


def _k_kubectl_label_namespace(pos, flags, snap, res, k, cfg, *_):
    pos_ns, lab = pos[0], pos[1]
    m = re.fullmatch(r"([a-zA-Z0-9._/-]+)=([a-zA-Z0-9._-]{0,63})", lab)
    if not m:
        res["blocked_reason"] = "label 要是 key=value(移除 label 不允許)"
        return None, [], None
    key, val = m.groups()
    if not key.startswith("pod-security.kubernetes.io/"):
        res["blocked_reason"] = "namespace label 只允許改 pod-security.kubernetes.io/*(其他標籤可能被 NetworkPolicy 選擇器使用)"
        return None, [], None
    old = (gglib.ptr_get(snap, "/metadata/labels") or {}).get(key)
    if old is not None and "--overwrite" not in flags:
        res["blocked_reason"] = f"label {key} 已有值 {old},要加 --overwrite"
        return None, [], None
    reasons = []
    if key.startswith("pod-security.kubernetes.io/"):
        if not key.endswith("-version") and val not in POD_SECURITY_ORDER:
            res["blocked_reason"] = f"Pod Security 等級不認得:{val}(只接受 privileged / baseline / restricted)"
            return None, [], None
        if key.endswith("-version"):
            reasons.append(f"變更 Pod Security 版本({key}: {old} → {val})")
        elif old is not None and POD_SECURITY_ORDER.get(val, -1) < POD_SECURITY_ORDER.get(old, -1):
            reasons.append(f"Pod Security {key.rsplit('/', 1)[1]} 由 {old} 降為 {val}")
        elif val not in POD_SECURITY_ORDER:
            res["blocked_reason"] = f"Pod Security 等級不認得:{val}"
            return None, [], None
    if key.startswith("pod-security.kubernetes.io/") and not key.endswith("-version") and (
            old is None or POD_SECURITY_ORDER.get(old, -1) < POD_SECURITY_ORDER.get(val, -1)):
        res["rollback_warning"] = f"還原會把 Pod Security {key.rsplit('/', 1)[1]} 降回 {old or '(未設定)'},執行前請確認"
    res["auto_pre"].append({"field": "/metadata/labels/" + key.replace("~", "~0").replace("/", "~1"), "expect": old})
    rb_label = f"{key}={old}" if old is not None else f"{key}-"
    return ["kubectl", f"--context={res['target']['context']}", "label", "namespace", pos_ns, rb_label,
            "--overwrite"], reasons, None
