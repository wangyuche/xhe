#!/usr/bin/env python3
"""底部訊號(依 Gg 2026-11-17 確認的規則,照順序判斷,前一步成立才看下一步)。
用法: python3 -I bottom_signal.py <30分K.json> [<60分K.json>] [--asof "YYYY-MM-DD HH:MM"] [--days 4] [--svg out.svg] [--title T]
資料: Fugle candles JSON({"data":[{date,open,high,low,close,volume}...]}),歷史 + 今天盤中已由 run.sh 合併。

流程(以 30 分 K 為主,只看最近 --days 個交易日,預設 4 天):
 ① 低檔鈍化  : D 值碰到 20 以下(碰一次就算)
 ② 底部背離  : 兩個相鄰的確認波段低點 a → b,前低 a 的 D < 20(在鈍化區),
                後低 b 價格更低、D 沒有創低(D[b] > D[a]),且 D[b] < 30
 ③ 黃金交叉  : 背離低點 b 之後,K 由下往上穿越 D,交叉那根 D < 50
 ④ 突破 20MA : 黃金交叉之後,看「當下這根」收盤是否在 MA20 上方(跌回就不算)
 ⑤ 突破下降壓力線: 黃金交叉之後,看當下這根收盤是否在壓力線上方;
                壓力線 = 背離低點 b 之前,最近兩個「後高 < 前高」的確認波段高點連線
 ⑥ 60 分 K 確認: 30 分 K 走到 ③ 之後,用同一套流程看 60 分 K 走到第幾步

KD(9,3,3): RSV 9 根;K = 2/3 前K + 1/3 RSV;D = 2/3 前D + 1/3 K;初值 50。
波段點: 前後各 3 根中的最低/最高,右邊 3 根走完才算確認(不偷看未來)。
30 分 K 的 13:30 收盤集合競價獨立 K 棒會併進 13:00(與 Fugle 60 分 K 一致)。"""
import datetime as _dt, json, sys

args = sys.argv[1:]
def opt(name, default=None):
    if name in args:
        i = args.index(name); v = args[i+1]; del args[i:i+2]; return v
    return default
asof = opt("--asof"); days = int(opt("--days", "4")); svg = opt("--svg"); title = opt("--title", "加權指數")
W = 3

def tstr(b): return b["date"][:16].replace("T", " ")

def load(path):
    raw = json.load(open(path))
    if not isinstance(raw, dict) or not raw.get("data"):
        sys.exit(f"資料錯誤: {path} 沒有 K 棒(Fugle 回應: {str(raw)[:200]})")
    merged = []
    for b in sorted(raw["data"], key=lambda b: b["date"]):
        p = merged[-1] if merged else None
        if b["date"][11:16] == "13:30" and p and p["date"][:10] == b["date"][:10]:
            p.update(high=max(p["high"], b["high"]), low=min(p["low"], b["low"]), close=b["close"],
                     volume=p.get("volume", 0) + b.get("volume", 0))
        else:
            merged.append(dict(b))
    if asof:
        merged = [b for b in merged if tstr(b) <= asof]
    return merged, int(raw.get("timeframe", "30") or 30)

class Series:
    def __init__(self, bars, tf):
        self.bars, self.tf = bars, tf
        n = self.n = len(bars)
        self.O = [b["open"] for b in bars]; self.H = [b["high"] for b in bars]
        self.L = [b["low"] for b in bars]; self.C = [b["close"] for b in bars]
        self.K, self.D = [], []
        k = d = 50.0
        for i in range(n):
            lo, hi = min(self.L[max(0, i-8):i+1]), max(self.H[max(0, i-8):i+1])
            rsv = 50.0 if hi == lo else (self.C[i] - lo) / (hi - lo) * 100
            k = 2/3*k + rsv/3; d = 2/3*d + k/3
            self.K.append(k); self.D.append(d)
        self.MA = [sum(self.C[i-19:i+1])/20 if i >= 19 else None for i in range(n)]
        dates = sorted({b["date"][:10] for b in bars})[-days:]
        self.w0 = next(i for i, b in enumerate(bars) if b["date"][:10] >= dates[0])
        self.last = n - 1
        self.lows = self._swings(self.L, True); self.highs = self._swings(self.H, False)

    def _swings(self, arr, is_low):
        out = []
        for i in range(W, self.n - W):
            seg = arr[i-W:i+W+1]
            if arr[i] == (min(seg) if is_low else max(seg)):
                if out and i - out[-1] <= W:
                    if (arr[i] < arr[out[-1]]) if is_low else (arr[i] > arr[out[-1]]):
                        out[-1] = i
                    continue
                out.append(i)
        return out

    def t(self, i): return tstr(self.bars[i])[5:].replace("-", "/")

    def run(self):
        """回傳 {stage, steps:{1..5: dict|None}}"""
        L, D, K, C, MA, H = self.L, self.D, self.K, self.C, self.MA, self.H
        w0, last = self.w0, self.last
        st = {}
        # ① 鈍化
        dz = [i for i in range(w0, last+1) if D[i] < 20]
        st[1] = {"i": dz[0], "min": min(D[i] for i in dz)} if dz else None
        # ② 背離(整組在回看範圍內)
        st[2] = None
        if st[1]:
            for j in range(len(self.lows)-1, 0, -1):
                a, b = self.lows[j-1], self.lows[j]
                if a < w0: break
                if D[a] < 20 and L[b] < L[a] and D[b] > D[a] and D[b] < 30:
                    st[2] = {"a": a, "i": b, "confirm": b + W}; break
        # ③ 黃金交叉
        st[3] = None
        if st[2]:
            b = st[2]["i"]
            for i in range(b+1, last+1):
                if K[i-1] <= D[i-1] and K[i] > D[i] and D[i] < 50:
                    st[3] = {"i": i}; break
        # ④ 20MA(當下這根)
        st[4] = st[5] = None
        if st[3]:
            if MA[last] and C[last] > MA[last]:
                first = next(i for i in range(st[3]["i"], last+1) if MA[i] and C[i] > MA[i])
                st[4] = {"i": first, "ma": MA[last]}
            # ⑤ 壓力線:背離低點之前的最近兩個下降波段高點
            b = st[2]["i"]
            hs = [h for h in self.highs if h < b]
            for j in range(len(hs)-1, 0, -1):
                a2, b2 = hs[j-1], hs[j]
                if H[b2] < H[a2]:
                    s = (H[b2]-H[a2])/(b2-a2); ln = lambda x: H[b2] + s*(x-b2)
                    if C[last] > ln(last):
                        first = next(i for i in range(st[3]["i"], last+1) if C[i] > ln(i))
                        st[5] = {"i": first, "a": a2, "b": b2, "line": ln(last)}
                    else:
                        self.line_info = {"a": a2, "b": b2, "line": ln(last)}
                    break
        stage = 0
        for s in (1, 2, 3):
            if st[s]: stage = s
            else: break
        if stage == 3: stage = 3 + (1 if st[4] else 0) + (1 if st[5] else 0)
        return {"stage": stage, "steps": st}

def report(S, r, label):
    st, t, D, K, L, C, MA = r["steps"], S.t, S.D, S.K, S.L, S.C, S.MA
    last = S.last
    end = _dt.datetime.strptime(tstr(S.bars[last]), "%Y-%m-%d %H:%M") + _dt.timedelta(minutes=S.tf)
    now = _dt.datetime.utcnow() + _dt.timedelta(hours=8)
    live = not asof and now < end and tstr(S.bars[last])[11:] < "13:30"
    out = [f"【{label}】{t(last)} 收 {C[last]:,.2f}  K {K[last]:.1f} / D {D[last]:.1f}  (回看 {days} 天:{t(S.w0)} 起)"
           + ("  ⚠️ 最後一根還沒走完,訊號可能變動" if live else "")]
    skip = "⏸ 前一步未成立,不判斷"
    s1 = st[1]
    out.append(f"① 低檔鈍化 D<20: " + (f"有 ✅ {t(s1['i'])} 起,最低 D {s1['min']:.1f}" if s1 else f"沒有 ❌(回看期間 D 最低 {min(D[S.w0:]):.1f})"))
    if not s1: out.append("② 底部背離: " + skip)
    elif st[2]:
        a, b = st[2]["a"], st[2]["i"]
        out.append(f"② 底部背離: 有 ✅ 前低 {t(a)} {L[a]:,.0f}(D{D[a]:.1f})→ 後低 {t(b)} {L[b]:,.0f}(D{D[b]:.1f}),{t(st[2]['confirm'])} 確認")
    else: out.append("② 底部背離: 沒有 ❌(需前低 D<20、後低價更低且 D 較高、D<30)")
    if not st[2]: out.append("③ 黃金交叉 D<50: " + skip)
    elif st[3]: out.append(f"③ 黃金交叉 D<50: 有 ✅ {t(st[3]['i'])} K{K[st[3]['i']]:.1f} 上穿 D{D[st[3]['i']]:.1f}")
    else: out.append(f"③ 黃金交叉 D<50: 沒有 ❌(目前 K{K[last]:.1f} {'>' if K[last] > D[last] else '<'} D{D[last]:.1f})")
    if not st[3]:
        out.append("④ 突破 20MA: " + skip); out.append("⑤ 突破下降壓力線: " + skip)
    else:
        out.append(f"④ 突破 20MA: 有 ✅ 當下收 {C[last]:,.0f} > MA20 {MA[last]:,.0f}(黃金交叉後 {t(st[4]['i'])} 首次站上)" if st[4]
                   else f"④ 突破 20MA: 沒有 ❌ 當下收 {C[last]:,.0f},MA20 {MA[last]:,.0f}(差 {C[last]-MA[last]:+,.0f})")
        if st[5]:
            e = st[5]; out.append(f"⑤ 突破下降壓力線: 有 ✅ 當下收 {C[last]:,.0f} > 線 {e['line']:,.0f}(線:{t(e['a'])} {S.H[e['a']]:,.0f} → {t(e['b'])} {S.H[e['b']]:,.0f})")
        elif getattr(S, "line_info", None):
            e = S.line_info; out.append(f"⑤ 突破下降壓力線: 沒有 ❌ 當下收 {C[last]:,.0f},線 {e['line']:,.0f}(差 {C[last]-e['line']:+,.0f})")
        else: out.append("⑤ 突破下降壓力線: 沒有 ❌(背離前找不到兩個下降的波段高點)")
    out.append(f"STAGE {r['stage']}/5")
    return "\n".join(out)

b30, tf30 = load(args[0])
S30 = Series(b30, tf30); r30 = S30.run()
print(report(S30, r30, f"{tf30}分K"))
r60 = None
if len(args) > 1:
    b60, tf60 = load(args[1])
    S60 = Series(b60, tf60); r60 = S60.run()
    print()
    if r30["stage"] >= 3:
        print("⑥ 60 分 K 確認(30 分 K 已到黃金交叉):")
        print(report(S60, r60, f"{tf60}分K"))
    else:
        print(f"⑥ 60 分 K 確認: ⏸ 30 分 K 還沒走到黃金交叉,先不看(參考:60 分 K 目前 STAGE {r60['stage']}/5)")

# 圖:30 分 K 走到 ② 背離以上才畫
if svg and r30["stage"] >= 2:
    S, st = S30, r30["steps"]
    n, last = S.n, S.last
    O, H, L, C, K, D, MA, t = S.O, S.H, S.L, S.C, S.K, S.D, S.MA, S.t
    i0 = max(0, min(S.w0, st[2]["a"]) - 5); N = n - i0 + 2
    Wd, Ht = 1200, 1200; Lm, Rm, T = 110, 40, 150
    P1b, P2t, P2b = 680, 885, 1120          # 價格 T..P1b;圖例 P1b..P2t;KD P2t..P2b
    lo = min(L[i0:]); hi = max(H[i0:]); pad = (hi-lo)*0.06; lo -= pad; hi += pad
    X = lambda i: Lm + (Wd-Lm-Rm)*(i-i0+0.5)/N
    Y = lambda v: T + (P1b-T)*(1-(v-lo)/(hi-lo))
    YK = lambda v: P2t + (P2b-P2t)*(1-v/100)
    f = 'font-family="PingFang TC, Heiti TC, sans-serif"'
    conf = f"　60分K STAGE {r60['stage']}/5" if r60 and r30["stage"] >= 3 else ""
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="900" height="900" viewBox="0 0 {Wd} {Ht}">',
         f'<rect width="{Wd}" height="{Ht}" fill="#fcfcfb"/>',
         f'<text x="{Lm}" y="60" {f} font-size="38" font-weight="600" fill="#0b0b0b">{title}　{S.tf}分K 底部訊號</text>',
         f'<text x="{Lm}" y="104" {f} font-size="24" fill="#52514e">{t(i0)} – {t(last)}　STAGE {r30["stage"]}/5{conf}　KD(9,3,3)　Fugle</text>']
    step = next(s for s in [10, 20, 50, 100, 200, 250, 500, 1000, 2000] if (hi-lo)/s <= 8)
    v = (int(lo/step)+1)*step
    while v < hi:
        o.append(f'<line x1="{Lm}" x2="{Wd-Rm}" y1="{Y(v):.1f}" y2="{Y(v):.1f}" stroke="#ecebe6"/>')
        o.append(f'<text x="{Lm-10}" y="{Y(v)+8:.1f}" {f} font-size="20" fill="#52514e" text-anchor="end">{v:,.0f}</text>'); v += step
    o.append(f'<rect x="{X(S.w0)-8:.1f}" y="{T}" width="{X(last)-X(S.w0)+16:.1f}" height="{P2b-T}" fill="#2b6cb0" opacity="0.04"/>')
    o.append(f'<rect x="{Lm}" y="{YK(20):.1f}" width="{Wd-Lm-Rm}" height="{YK(0)-YK(20):.1f}" fill="#1e8449" opacity="0.07"/>')
    for lv in (20, 30, 50, 80):
        o.append(f'<line x1="{Lm}" x2="{Wd-Rm}" y1="{YK(lv):.1f}" y2="{YK(lv):.1f}" stroke="#e2e1dc" stroke-dasharray="{"6 4" if lv in (20, 30, 50) else "0"}"/>')
        o.append(f'<text x="{Lm-10}" y="{YK(lv)+7:.1f}" {f} font-size="20" fill="#52514e" text-anchor="end">{lv}</text>')
    o.append(f'<text x="{Lm+6}" y="{P2t-10}" {f} font-size="22" fill="#52514e">KD　<tspan fill="#2b6cb0">K</tspan>　<tspan fill="#e08a1e">D</tspan>　綠底＝D&lt;20 鈍化區</text>')
    prev, lastx = None, -999
    for i in range(i0, n):
        day = tstr(S.bars[i])[5:10]
        if day != prev and X(i) - lastx > 60:
            o.append(f'<line x1="{X(i)-8:.1f}" x2="{X(i)-8:.1f}" y1="{T}" y2="{P2b}" stroke="#f1f0ec"/>')
            o.append(f'<text x="{X(i):.1f}" y="{P2b+34}" {f} font-size="20" fill="#52514e">{day.replace("-", "/")}</text>'); lastx = X(i)
        prev = day
    pts = [(i, MA[i]) for i in range(i0, n) if MA[i]]
    o.append('<path d="' + " ".join(f'{"M" if j == 0 else "L"}{X(i):.1f},{Y(m):.1f}' for j, (i, m) in enumerate(pts)) + '" fill="none" stroke="#e08a1e" stroke-width="2.5"/>')
    o.append(f'<text x="{Wd-Rm-150}" y="{T-12}" {f} font-size="22" fill="#e08a1e">— MA20</text>')
    cw = (Wd-Lm-Rm)/N*0.6
    for i in range(i0, n):
        col = "#d64545" if C[i] >= O[i] else "#2f9e5a"
        o.append(f'<line x1="{X(i):.1f}" x2="{X(i):.1f}" y1="{Y(H[i]):.1f}" y2="{Y(L[i]):.1f}" stroke="{col}" stroke-width="1.5"/>')
        yt, yb = Y(max(O[i], C[i])), Y(min(O[i], C[i]))
        o.append(f'<rect x="{X(i)-cw/2:.1f}" y="{yt:.1f}" width="{cw:.1f}" height="{max(yb-yt, 1.5):.1f}" fill="{col}"/>')
    for arr, colr in ((K, "#2b6cb0"), (D, "#e08a1e")):
        o.append('<path d="' + " ".join(f'{"M" if j == 0 else "L"}{X(i):.1f},{YK(arr[i]):.1f}' for j, i in enumerate(range(i0, n))) + f'" fill="none" stroke="{colr}" stroke-width="2.2"/>')
    def badge(x, y, num, colr):
        o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="17" fill="{colr}"/>')
        o.append(f'<text x="{x:.1f}" y="{y+8:.1f}" {f} font-size="22" font-weight="700" fill="#fff" text-anchor="middle">{num}</text>')
    GRN, BLU, ORG, PUR = "#1e8449", "#2b6cb0", "#c0392b", "#7b3fbf"
    legend = []
    a, b = st[2]["a"], st[2]["i"]
    o.append(f'<line x1="{X(a):.1f}" y1="{Y(L[a]):.1f}" x2="{X(b):.1f}" y2="{Y(L[b]):.1f}" stroke="{GRN}" stroke-width="3" stroke-dasharray="8 5"/>')
    o.append(f'<line x1="{X(a):.1f}" y1="{YK(D[a]):.1f}" x2="{X(b):.1f}" y2="{YK(D[b]):.1f}" stroke="{GRN}" stroke-width="3" stroke-dasharray="8 5"/>')
    badge(X(b), Y(L[b]) + 34, 2, GRN)
    legend.append((2, GRN, f"背離 {t(a)} {L[a]:,.0f}(D{D[a]:.0f}) → {t(b)} {L[b]:,.0f}(D{D[b]:.0f})"))
    if st[3]:
        i = st[3]["i"]
        o.append(f'<circle cx="{X(i):.1f}" cy="{YK(D[i]):.1f}" r="9" fill="none" stroke="{BLU}" stroke-width="3"/>')
        badge(X(i), YK(D[i]) - 34, 3, BLU)
        legend.append((3, BLU, f"黃金交叉 {t(i)}　K{K[i]:.0f} 上穿 D{D[i]:.0f}"))
    if st[4]:
        i = st[4]["i"]
        o.append(f'<circle cx="{X(i):.1f}" cy="{Y(MA[i]):.1f}" r="9" fill="none" stroke="{ORG}" stroke-width="3"/>')
        badge(X(i) + 30, Y(MA[i]) + 60, 4, ORG)
        legend.append((4, ORG, f"站上 20MA {t(i)}　當下收 {C[last]:,.0f} > {MA[last]:,.0f}"))
    li = st[5] or getattr(S, "line_info", None)
    if li:
        a2, b2 = li["a"], li["b"]; s = (H[b2]-H[a2])/(b2-a2); xa = max(a2, i0)
        o.append(f'<line x1="{X(xa):.1f}" y1="{Y(H[b2]+s*(xa-b2)):.1f}" x2="{X(last):.1f}" y2="{Y(H[b2]+s*(last-b2)):.1f}" stroke="{PUR}" stroke-width="3"/>')
        for j in (a2, b2):
            if j >= i0: o.append(f'<circle cx="{X(j):.1f}" cy="{Y(H[j]):.1f}" r="7" fill="none" stroke="{PUR}" stroke-width="2.5"/>')
        if st[5]:
            i = st[5]["i"]
            o.append(f'<path d="M{X(i):.1f},{Y(H[i])-14:.1f} l-9,-18 h18 z" fill="{PUR}"/>')
            badge(X(i), Y(H[i]) - 48, 5, PUR)
            legend.append((5, PUR, f"突破壓力線 {t(i)}　當下收 {C[last]:,.0f} > 線 {st[5]['line']:,.0f}"))
    ly = P1b + 62
    o.append(f'<rect x="{Lm+8}" y="{ly-26}" width="660" height="{30*len(legend)+16}" fill="#fcfcfb" opacity="0.92" stroke="#e2e1dc"/>')
    for k2, (num, colr, txt) in enumerate(sorted(legend)):
        yy = ly + 30*k2
        o.append(f'<circle cx="{Lm+28}" cy="{yy-6}" r="11" fill="{colr}"/>')
        o.append(f'<text x="{Lm+28}" y="{yy}" {f} font-size="15" font-weight="700" fill="#fff" text-anchor="middle">{num}</text>')
        o.append(f'<text x="{Lm+48}" y="{yy}" {f} font-size="21" fill="#0b0b0b">{txt}</text>')
    o.append("</svg>")
    open(svg, "w").write("\n".join(o))
    print(f"SVG {svg}")
