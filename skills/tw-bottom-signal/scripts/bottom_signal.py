#!/usr/bin/env python3
"""底部訊號檢查(30 分 / 60 分 K),可輸出標記圖。
用法: python3 -I bottom_signal.py <candles.json> <label> [--asof "YYYY-MM-DD HH:MM"] [--lookback N] [--svg out.svg] [--title T]
資料: fugle.sh "historical/candles/<代號>?timeframe=30|60&from=..&to=.." <out>(Fugle 歷史 K,含當日)
訊號(在最近 lookback 根內出現過即算「有」,預設 10 根):
 1. D 值底部背離: 確認的波段低點 b 與前一個波段低點 a,L[b] < L[a] 且 D[b] > D[a]
 2. D≥20 黃金交叉: K 由下往上穿越 D,交叉那根 D >= 20
 3. 突破下降壓力線: 當時已確認的最近兩個波段高點(後高 < 前高)連線,收盤由線下站上線上
 4. 突破 20MA: 收盤由 MA20 下方站上上方
KD(9,3,3): RSV 9 根;K = 2/3 K前 + 1/3 RSV;D = 2/3 D前 + 1/3 K;初值 50。
波段點: 前後各 W=3 根中的最高/最低;要等右邊 3 根走完才算確認(避免未來函數)。"""
import json, sys

args = sys.argv[1:]
def opt(name, default=None):
    if name in args:
        i = args.index(name); v = args[i+1]; del args[i:i+2]; return v
    return default
asof = opt("--asof"); dmin = float(opt("--dmin", "20")); lookback = int(opt("--lookback", "10")); svg = opt("--svg"); title = opt("--title", "加權指數")
src, label = args[0], (args[1] if len(args) > 1 else "")
W = 3

raw = json.load(open(src))
if not isinstance(raw, dict) or not raw.get("data"):
    sys.exit(f"資料錯誤: {src} 沒有 K 棒(Fugle 回應: {str(raw)[:200]})")
bars = sorted(raw["data"], key=lambda b: b["date"])
def tstr(b): return b["date"][:16].replace("T", " ")
# Fugle 30 分 K 會把 13:30 收盤集合競價拆成獨立一根(開高低收同價),一般看盤軟體併在 13:00 那根。
# 不合併的話每天多一根平線,KD 與 MA20 都會偏掉。
merged = []
for b in bars:
    p = merged[-1] if merged else None
    if b["date"][11:16] == "13:30" and p and p["date"][:10] == b["date"][:10]:
        p.update(high=max(p["high"], b["high"]), low=min(p["low"], b["low"]), close=b["close"],
                 volume=p.get("volume", 0) + b.get("volume", 0))
    else:
        merged.append(dict(b))
bars = merged
if asof:
    bars = [b for b in bars if tstr(b) <= asof]
n = len(bars)
O = [b["open"] for b in bars]; H = [b["high"] for b in bars]; L = [b["low"] for b in bars]; C = [b["close"] for b in bars]
K, D = [], []
k = d = 50.0
for i in range(n):
    lo, hi = min(L[max(0, i-8):i+1]), max(H[max(0, i-8):i+1])
    rsv = 50.0 if hi == lo else (C[i] - lo) / (hi - lo) * 100
    k = 2/3*k + rsv/3; d = 2/3*d + k/3
    K.append(k); D.append(d)
MA = [sum(C[i-19:i+1])/20 if i >= 19 else None for i in range(n)]
def t(i): return tstr(bars[i])[5:].replace("-", "/")

def swings(arr, is_low):
    out = []
    for i in range(W, n - W):
        seg = arr[i-W:i+W+1]
        if arr[i] == (min(seg) if is_low else max(seg)):
            if out and i - out[-1] <= W:
                if (arr[i] < arr[out[-1]]) if is_low else (arr[i] > arr[out[-1]]):
                    out[-1] = i
                continue
            out.append(i)
    return out
lows, highs = swings(L, True), swings(H, False)

ev = {1: [], 2: [], 3: [], 4: []}
for j in range(1, len(lows)):
    a, b = lows[j-1], lows[j]
    if L[b] < L[a] and D[b] > D[a]:
        ev[1].append({"i": b, "a": a, "confirm": b + W})
for i in range(1, n):
    if K[i-1] <= D[i-1] and K[i] > D[i] and D[i] >= dmin:
        ev[2].append({"i": i})
    if MA[i] and MA[i-1] and C[i-1] <= MA[i-1] and C[i] > MA[i]:
        ev[4].append({"i": i})
    hs = [h for h in highs if h + W <= i]       # 已確認的高點
    for j in range(len(hs)-1, 0, -1):
        a, b = hs[j-1], hs[j]
        if H[b] < H[a]:
            s = (H[b]-H[a])/(b-a); ln = lambda x: H[b] + s*(x-b)
            if C[i-1] <= ln(i-1) and C[i] > ln(i):
                ev[3].append({"i": i, "a": a, "b": b, "line": ln(i)})
            break

last = n - 1
recent = {s: [e for e in ev[s] if e.get("confirm", e["i"]) > last - lookback] for s in ev}
name = {1: "D值底部背離", 2: "D≥20 黃金交叉", 3: "突破下降壓力線", 4: "突破 20MA"}
# 盤中最後一根還沒走完,訊號可能消失
import datetime as _dt
tf = int(raw.get("timeframe", "30") or 30)
end = _dt.datetime.strptime(tstr(bars[last]), "%Y-%m-%d %H:%M") + _dt.timedelta(minutes=tf)
now = _dt.datetime.utcnow() + _dt.timedelta(hours=8)
live = not asof and now < end and tstr(bars[last])[11:] < "13:30"
print(f"【{label}】{t(last)} 收 {C[last]:,.2f}  K {K[last]:.1f} / D {D[last]:.1f}  (看最近 {lookback} 根)"
      + ("  ⚠️ 最後一根還沒走完,訊號可能變動" if live else ""))
for s in (1, 2, 3, 4):
    if recent[s]:
        e = recent[s][-1]; i = e["i"]
        if s == 1:
            a = e["a"]; detail = f"前低 {t(a)} {L[a]:,.0f}(D{D[a]:.1f}) → 後低 {t(i)} {L[i]:,.0f}(D{D[i]:.1f}),{t(e['confirm'])} 確認"
        elif s == 2:
            detail = f"{t(i)} K{K[i]:.1f} 上穿 D{D[i]:.1f}"
        elif s == 3:
            detail = f"{t(i)} 收 {C[i]:,.0f} 站上壓力線 {e['line']:,.0f}(線: {t(e['a'])} {H[e['a']]:,.0f} → {t(e['b'])} {H[e['b']]:,.0f})"
        else:
            detail = f"{t(i)} 收 {C[i]:,.0f} 站上 MA20 {MA[i]:,.0f}"
        print(f"{s}. {name[s]}: 有 ✅ {detail}")
    else:
        extra = ""
        if s == 4 and MA[last]: extra = f"(MA20 {MA[last]:,.0f},收盤差 {C[last]-MA[last]:+,.0f})"
        if s == 2: extra = f"(目前 K{K[last]:.1f} {'>' if K[last] > D[last] else '<'} D{D[last]:.1f})"
        print(f"{s}. {name[s]}: 沒有 ❌{extra}")
hit = sum(1 for s in recent if recent[s])
print(f"HITS {hit}/4")

if svg and hit:
    # 只畫最近 60 根
    i0 = max(0, n - 60); N = n - i0 + 2
    Wd, Ht = 1200, 1200; Lm, Rm, T = 110, 40, 150
    P1b, P2t, P2b = 800, 850, 1120          # 價格區 T..P1b,KD 區 P2t..P2b
    lo = min(L[i0:]); hi = max(H[i0:]); pad = (hi-lo)*0.06; lo -= pad; hi += pad
    X = lambda i: Lm + (Wd-Lm-Rm)*(i-i0+0.5)/N
    Y = lambda v: T + (P1b-T)*(1-(v-lo)/(hi-lo))
    YK = lambda v: P2t + (P2b-P2t)*(1-v/100)
    f = 'font-family="PingFang TC, Heiti TC, sans-serif"'
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="900" height="900" viewBox="0 0 {Wd} {Ht}">',
         f'<rect width="{Wd}" height="{Ht}" fill="#fcfcfb"/>',
         f'<text x="{Lm}" y="60" {f} font-size="38" font-weight="600" fill="#0b0b0b">{title}　{label}底部訊號</text>',
         f'<text x="{Lm}" y="104" {f} font-size="24" fill="#52514e">{t(i0)} – {t(last)}　出現 {hit}/4　KD(9,3,3)　資料:Fugle</text>']
    step = next(s for s in [10, 20, 50, 100, 200, 250, 500, 1000, 2000] if (hi-lo)/s <= 8)
    v = (int(lo/step)+1)*step
    while v < hi:
        o.append(f'<line x1="{Lm}" x2="{Wd-Rm}" y1="{Y(v):.1f}" y2="{Y(v):.1f}" stroke="#ecebe6"/>')
        o.append(f'<text x="{Lm-10}" y="{Y(v)+8:.1f}" {f} font-size="20" fill="#52514e" text-anchor="end">{v:,.0f}</text>'); v += step
    for lv in (20, 50, 80):
        o.append(f'<line x1="{Lm}" x2="{Wd-Rm}" y1="{YK(lv):.1f}" y2="{YK(lv):.1f}" stroke="#ecebe6" stroke-dasharray="{"6 4" if lv == 20 else "0"}"/>')
        o.append(f'<text x="{Lm-10}" y="{YK(lv)+7:.1f}" {f} font-size="20" fill="#52514e" text-anchor="end">{lv}</text>')
    o.append(f'<text x="{Lm+6}" y="{P2t-10}" {f} font-size="22" fill="#52514e">KD　<tspan fill="#2b6cb0">K</tspan>　<tspan fill="#e08a1e">D</tspan></text>')
    prev = None
    for i in range(i0, n):
        day = tstr(bars[i])[5:10]
        if day != prev and (prev is None or X(i) - lastx > 60):
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
    for key, arr, colr in (("K", K, "#2b6cb0"), ("D", D, "#e08a1e")):
        o.append('<path d="' + " ".join(f'{"M" if j == 0 else "L"}{X(i):.1f},{YK(arr[i]):.1f}' for j, i in enumerate(range(i0, n))) + f'" fill="none" stroke="{colr}" stroke-width="2.2"/>')
    def badge(x, y, num, colr):
        o.append(f'<circle cx="{x:.1f}" cy="{y:.1f}" r="17" fill="{colr}"/>')
        o.append(f'<text x="{x:.1f}" y="{y+8:.1f}" {f} font-size="22" font-weight="700" fill="#fff" text-anchor="middle">{num}</text>')
    legend = []
    PUR, GRN, BLU, ORG = "#7b3fbf", "#1e8449", "#2b6cb0", "#c0392b"
    for e in recent[1][-1:]:
        a, b = e["a"], e["i"]
        if a >= i0:
            o.append(f'<line x1="{X(a):.1f}" y1="{Y(L[a]):.1f}" x2="{X(b):.1f}" y2="{Y(L[b]):.1f}" stroke="{GRN}" stroke-width="3" stroke-dasharray="8 5"/>')
            o.append(f'<line x1="{X(a):.1f}" y1="{YK(D[a]):.1f}" x2="{X(b):.1f}" y2="{YK(D[b]):.1f}" stroke="{GRN}" stroke-width="3" stroke-dasharray="8 5"/>')
        badge(X(b), Y(L[b]) + 34, 1, GRN)
        legend.append((1, GRN, f"底部背離 {t(b)}　價 {L[b]:,.0f} 創低、D {D[b]:.0f} 未創低"))
    for e in recent[2][-1:]:
        i = e["i"]
        o.append(f'<circle cx="{X(i):.1f}" cy="{YK(D[i]):.1f}" r="9" fill="none" stroke="{BLU}" stroke-width="3"/>')
        badge(X(i), YK(D[i]) - 34, 2, BLU)
        legend.append((2, BLU, f"黃金交叉 {t(i)}　K{K[i]:.0f} 上穿 D{D[i]:.0f}"))
    for e in recent[3][-1:]:
        a, b, i = e["a"], e["b"], e["i"]
        s = (H[b]-H[a])/(b-a); xa = max(a, i0)
        o.append(f'<line x1="{X(xa):.1f}" y1="{Y(H[b]+s*(xa-b)):.1f}" x2="{X(n-1):.1f}" y2="{Y(H[b]+s*(n-1-b)):.1f}" stroke="{PUR}" stroke-width="3"/>')
        for j in (a, b):
            if j >= i0: o.append(f'<circle cx="{X(j):.1f}" cy="{Y(H[j]):.1f}" r="7" fill="none" stroke="{PUR}" stroke-width="2.5"/>')
        o.append(f'<path d="M{X(i):.1f},{Y(C[i])-14:.1f} l-9,-18 h18 z" fill="{PUR}"/>')
        badge(X(i), Y(H[i]) - 48, 3, PUR)
        legend.append((3, PUR, f"突破下降壓力線 {t(i)}　收 {C[i]:,.0f} > 線 {e['line']:,.0f}"))
    for e in recent[4][-1:]:
        i = e["i"]
        o.append(f'<circle cx="{X(i):.1f}" cy="{Y(MA[i]):.1f}" r="9" fill="none" stroke="{ORG}" stroke-width="3"/>')
        badge(X(i) + 30, Y(MA[i]) + 60, 4, ORG)
        legend.append((4, ORG, f"突破 20MA {t(i)}　收 {C[i]:,.0f} > MA20 {MA[i]:,.0f}"))
    y = 140
    for num, colr, txt in sorted(legend):
        pass
    ly = P1b - 30*len(legend) - 10
    o.append(f'<rect x="{Lm+8}" y="{ly-26}" width="640" height="{30*len(legend)+16}" fill="#fcfcfb" opacity="0.92" stroke="#e2e1dc"/>')
    for k2, (num, colr, txt) in enumerate(sorted(legend)):
        yy = ly + 30*k2
        o.append(f'<circle cx="{Lm+28}" cy="{yy-6}" r="11" fill="{colr}"/>')
        o.append(f'<text x="{Lm+28}" y="{yy}" {f} font-size="15" font-weight="700" fill="#fff" text-anchor="middle">{num}</text>')
        o.append(f'<text x="{Lm+48}" y="{yy}" {f} font-size="21" fill="#0b0b0b">{txt}</text>')
    o.append("</svg>")
    open(svg, "w").write("\n".join(o))
    print(f"SVG {svg}")
