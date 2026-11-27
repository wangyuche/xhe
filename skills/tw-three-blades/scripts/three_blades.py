#!/usr/bin/env python3
"""刀神「均線三刀流」(依《海期刀神教你用100張圖實戰均線三刀流》《海期刀神的60分K獲利術》公開介紹的做法)。
用法: python3 -I three_blades.py <60分K.json> [--asof "YYYY-MM-DD HH:MM"] [--slope-n 5] [--svg out.svg] [--title T]
資料: Fugle candles JSON({"data":[{date,open,high,low,close,volume}...]}),歷史 + 今天盤中已由 run.sh 合併。

做法(60 分 K,簡單移動平均):
  小藍 = 20MA、小綠 = 60MA、小橘 = 240MA(大魔王)
  方向  : 小橘斜率為正 = 多方環境;為負 = 空方環境(切忌積極做多)。另列價格在小橘上方或下方
  進場  : 小藍上穿小綠(藍綠黃金交叉)＋ KD 轉強(K > D)= 做多的第一步;
          小藍下穿小綠(藍綠死亡交叉)= 往下走的徵兆
  排列  : 小藍 > 小綠 > 小橘 = 多頭排列;反之空頭排列;其他 = 糾結
  不逆勢: 價格還沒站上小藍、小綠,尤其小橘之前,不挑戰均線
  雙斜率: 小藍、小綠斜率與小橘同方向時,勝率較高
斜率 = 這根的 MA 減 --slope-n 根前的 MA(預設 5 根 ≈ 1 個交易日),只看正負。
KD(9,3,3):RSV 9 根;K = 2/3 前K + 1/3 RSV;D = 2/3 前D + 1/3 K;初值 50。
"""
import datetime as _dt, json, sys

args = sys.argv[1:]
def opt(name, default=None):
    if name in args:
        i = args.index(name); v = args[i+1]; del args[i:i+2]; return v
    return default
asof = opt("--asof"); slope_n = int(opt("--slope-n", "5")); svg = opt("--svg"); title = opt("--title", "加權指數")
PER = (20, 60, 240)
NAME = {20: "小藍 20MA", 60: "小綠 60MA", 240: "小橘 240MA"}
COL = {20: "#2b6cb0", 60: "#1e8449", 240: "#e08a1e"}

def tstr(b): return b["date"][:16].replace("T", " ")

if not args:
    sys.exit("用法: python3 -I three_blades.py <60分K.json> [--asof ...] [--slope-n 5] [--svg out.svg] [--title T]")
try:
    raw = json.load(open(args[0]))
except Exception as e:
    sys.exit(f"資料錯誤: 讀不到 {args[0]}: {e}")
if not isinstance(raw, dict) or not raw.get("data"):
    sys.exit(f"資料錯誤: {args[0]} 沒有 K 棒(Fugle 回應: {str(raw)[:200]})")
bars = sorted({b["date"]: b for b in raw["data"]}.values(), key=lambda b: b["date"])
if asof:
    bars = [b for b in bars if tstr(b) <= asof]
n = len(bars)
need = 240 + slope_n + 1
if n < need:
    sys.exit(f"資料錯誤: 60 分 K 只有 {n} 根,算 240MA 與斜率至少要 {need} 根")
O = [b["open"] for b in bars]; H = [b["high"] for b in bars]
L = [b["low"] for b in bars]; C = [b["close"] for b in bars]
MA = {p: [sum(C[i-p+1:i+1])/p if i >= p-1 else None for i in range(n)] for p in PER}
K, D = [], []
k = d = 50.0
for i in range(n):
    lo, hi = min(L[max(0, i-8):i+1]), max(H[max(0, i-8):i+1])
    rsv = 50.0 if hi == lo else (C[i] - lo) / (hi - lo) * 100
    k = 2/3*k + rsv/3; d = 2/3*d + k/3
    K.append(k); D.append(d)
last = n - 1
def slope(p, i):
    a, b = MA[p][i], MA[p][i-slope_n] if i-slope_n >= 0 else None
    return None if a is None or b is None else a - b
t = lambda i: tstr(bars[i])[5:].replace("-", "/")
def px(v):   # 指數、高價股取整數;低價股保留小數(65.8 不要變 66)
    if abs(v) >= 1000: return f"{v:,.0f}"
    s = f"{v:,.2f}".rstrip("0").rstrip("."); return s

# 藍綠交叉(全部列出,最後一次是目前訊號)
crosses = []
for i in range(1, n):
    a0, b0, a1, b1 = MA[20][i-1], MA[60][i-1], MA[20][i], MA[60][i]
    if None in (a0, b0, a1, b1): continue
    if a0 <= b0 and a1 > b1: crosses.append(("黃金交叉", i))
    elif a0 >= b0 and a1 < b1: crosses.append(("死亡交叉", i))
# 小橘斜率、小藍斜率最近一次翻轉
def last_flip(p):
    prev = None
    for i in range(last, 0, -1):
        s = slope(p, i)
        if s is None: break
        sg = s > 0
        if prev is None: prev = sg; continue
        if sg != prev: return i + 1, prev
    return None, prev
# 價格最近一次穿越某條均線(收盤由下往上 = 站上;由上往下 = 跌破)
def last_cross_price(p):
    for i in range(last, 0, -1):
        m0, m1 = MA[p][i-1], MA[p][i]
        if m0 is None or m1 is None: break
        if C[i-1] <= m0 and C[i] > m1: return i, "站上"
        if C[i-1] >= m0 and C[i] < m1: return i, "跌破"
    return None, None

end = _dt.datetime.strptime(tstr(bars[last]), "%Y-%m-%d %H:%M") + _dt.timedelta(minutes=60)
now = _dt.datetime.utcnow() + _dt.timedelta(hours=8)
live = not asof and now < end
out = [f"【60分K 均線三刀流】{t(last)} 收 {px(C[last])}  K {K[last]:.1f} / D {D[last]:.1f}  斜率=比 {slope_n} 根前"
       + ("  ⚠️ 最後一根還沒走完,訊號可能變動" if live else "")]
sg = {}
for p in PER:
    m = MA[p][last]; s = slope(p, last); sg[p] = s > 0
    ci, kind = last_cross_price(p)
    since = f",{t(ci)} {kind}" if ci else ""
    sgn = lambda v: ("+" if v >= 0 else "-") + px(abs(v))
    out.append(f"{NAME[p]} {px(m)}:價格在{'上' if C[last] > m else '下'}方 {sgn(C[last]-m)}、斜率{'正 ↗' if s > 0 else '負 ↘'}({sgn(s)}){since}")
m20, m60, m240 = MA[20][last], MA[60][last], MA[240][last]
order = "多頭排列(小藍>小綠>小橘)" if m20 > m60 > m240 else "空頭排列(小藍<小綠<小橘)" if m20 < m60 < m240 else "糾結(非多空排列)"
out.append(f"排列:{order}")
fi, before = last_flip(240)
env = "多方環境" if sg[240] else "空方環境"
flip = f"(小橘斜率 {t(fi)} 由{'負轉正' if before else '正轉負'})" if fi else ""   # before = 目前的斜率方向
pos240 = "價格在小橘之上" if C[last] > m240 else "價格在小橘之下"
out.append(f"① 方向(小橘斜率):{env}{flip};{pos240}" + ("" if sg[240] or C[last] < m240 else " → 斜率仍負,切忌積極做多")
           + (" → 斜率為正但價格已跌破小橘,多方結構受損" if sg[240] and C[last] < m240 else ""))
if crosses:
    kind, ci = crosses[-1]
    kd_now = "K>D 轉強" if K[last] > D[last] else "K<D 轉弱"
    out.append(f"② 藍綠交叉:最近一次 {t(ci)} {kind}(交叉那根收 {px(C[ci])},K{K[ci]:.0f}/D{D[ci]:.0f});目前 KD {kd_now}")
else:
    out.append("② 藍綠交叉:資料期間內沒有交叉")
dbl = [NAME[p].split()[0] for p in (20, 60) if sg[p] == sg[240]]
out.append(f"③ 雙斜率:" + (f"{'、'.join(dbl)}與小橘同方向" if dbl else "小藍、小綠都與小橘反方向"))
above_all = all(C[last] > MA[p][last] for p in PER)
below_all = all(C[last] < MA[p][last] for p in PER)
out.append("④ 不逆勢:" + ("價格站上三條線" if above_all else "價格在三條線之下" if below_all
           else "價格還沒全部站上(" + "、".join(NAME[p].split()[0] for p in PER if C[last] <= MA[p][last]) + " 在上方壓著)"))
# 綜合:書中的順勢條件
gold = crosses and crosses[-1][0] == "黃金交叉"
if sg[240] and gold and K[last] > D[last] and above_all:
    verdict = "偏多:小橘向上＋藍綠黃金交叉＋KD 轉強＋價格站上三線,符合書中做多條件"
elif (not sg[240]) and crosses and not gold and below_all:
    verdict = "偏空:小橘向下＋藍綠死亡交叉＋價格在三線之下"
elif sg[240]:
    verdict = "多方環境但條件未齊(" + ("藍綠未金叉" if not gold else "KD 未轉強" if K[last] <= D[last] else "價格未站上三線") + "),等條件到齊"
else:
    verdict = "空方環境" + ("但出現藍綠黃金交叉,屬逆勢反彈,書中建議不積極做多" if gold else ",條件未齊")
out.append(f"結論:{verdict}")
print("\n".join(out))

# ---- 圖:最近約 15 個交易日的 60 分 K ＋ 三條均線 ＋ 藍綠交叉 ----
if svg:
    i0 = max(0, n - 75); N = n - i0 + 2
    Wd, Ht, Lm, Rm, T, P1b, P2t, P2b = 1200, 1200, 110, 40, 160, 820, 900, 1110
    vals = [v for i in range(i0, n) for v in (L[i], H[i]) + tuple(MA[p][i] for p in PER if MA[p][i])]
    lo, hi = min(vals), max(vals); pad = (hi-lo)*0.05; lo -= pad; hi += pad
    X = lambda i: Lm + (Wd-Lm-Rm)*(i-i0+0.5)/N
    Y = lambda v: T + (P1b-T)*(1-(v-lo)/(hi-lo))
    YK = lambda v: P2t + (P2b-P2t)*(1-v/100)
    f = 'font-family="PingFang TC, Heiti TC, sans-serif"'
    o = [f'<svg xmlns="http://www.w3.org/2000/svg" width="900" height="900" viewBox="0 0 {Wd} {Ht}">',
         f'<rect width="{Wd}" height="{Ht}" fill="#fcfcfb"/>',
         f'<text x="{Lm}" y="60" {f} font-size="38" font-weight="600" fill="#0b0b0b">{title}　60分K 均線三刀流</text>',
         f'<text x="{Lm}" y="104" {f} font-size="24" fill="#52514e">{t(i0)} – {t(last)}　收 {px(C[last])}　{env}　{order.split("(")[0]}　Fugle</text>']
    lg = "　".join(f'<tspan fill="{COL[p]}">— {NAME[p]} {px(MA[p][last])}</tspan>' for p in PER)
    o.append(f'<text x="{Lm}" y="{T-20}" {f} font-size="22">{lg}</text>')
    step = next(s for s in [50, 100, 200, 250, 500, 1000, 2000] if (hi-lo)/s <= 9)
    v = (int(lo/step)+1)*step
    while v < hi:
        o.append(f'<line x1="{Lm}" x2="{Wd-Rm}" y1="{Y(v):.1f}" y2="{Y(v):.1f}" stroke="#ecebe6"/>')
        o.append(f'<text x="{Lm-10}" y="{Y(v)+8:.1f}" {f} font-size="20" fill="#52514e" text-anchor="end">{v:,.0f}</text>'); v += step
    for lv in (20, 50, 80):
        o.append(f'<line x1="{Lm}" x2="{Wd-Rm}" y1="{YK(lv):.1f}" y2="{YK(lv):.1f}" stroke="#e2e1dc" stroke-dasharray="6 4"/>')
        o.append(f'<text x="{Lm-10}" y="{YK(lv)+7:.1f}" {f} font-size="20" fill="#52514e" text-anchor="end">{lv}</text>')
    o.append(f'<text x="{Lm+6}" y="{P2t-12}" {f} font-size="22" fill="#52514e">KD(9,3,3)　<tspan fill="#2b6cb0">K</tspan>　<tspan fill="#c0392b">D</tspan></text>')
    prev, lastx = None, -999
    for i in range(i0, n):
        day = tstr(bars[i])[5:10]
        if day != prev and X(i) - lastx > 60:
            o.append(f'<line x1="{X(i)-6:.1f}" x2="{X(i)-6:.1f}" y1="{T}" y2="{P2b}" stroke="#f1f0ec"/>')
            o.append(f'<text x="{X(i):.1f}" y="{P2b+34}" {f} font-size="20" fill="#52514e">{day.replace("-", "/")}</text>'); lastx = X(i)
        prev = day
    cw = (Wd-Lm-Rm)/N*0.6
    for i in range(i0, n):
        col = "#d64545" if C[i] >= O[i] else "#2f9e5a"
        o.append(f'<line x1="{X(i):.1f}" x2="{X(i):.1f}" y1="{Y(H[i]):.1f}" y2="{Y(L[i]):.1f}" stroke="{col}" stroke-width="1.4"/>')
        yt, yb = Y(max(O[i], C[i])), Y(min(O[i], C[i]))
        o.append(f'<rect x="{X(i)-cw/2:.1f}" y="{yt:.1f}" width="{cw:.1f}" height="{max(yb-yt, 1.5):.1f}" fill="{col}"/>')
    for p in PER:
        pts = [(i, MA[p][i]) for i in range(i0, n) if MA[p][i]]
        o.append('<path d="' + " ".join(f'{"M" if j == 0 else "L"}{X(i):.1f},{Y(m):.1f}' for j, (i, m) in enumerate(pts))
                 + f'" fill="none" stroke="{COL[p]}" stroke-width="3"/>')
    for arr, colr in ((K, "#2b6cb0"), (D, "#c0392b")):
        o.append('<path d="' + " ".join(f'{"M" if j == 0 else "L"}{X(i):.1f},{YK(arr[i]):.1f}' for j, i in enumerate(range(i0, n)))
                 + f'" fill="none" stroke="{colr}" stroke-width="2"/>')
    for kind, i in crosses:
        if i < i0: continue
        y = Y(MA[20][i]); up = kind == "黃金交叉"; colr = "#c0392b" if up else "#1e8449"
        o.append(f'<circle cx="{X(i):.1f}" cy="{y:.1f}" r="9" fill="none" stroke="{colr}" stroke-width="3"/>')
        ty = y + (46 if up else -26)
        o.append(f'<text x="{X(i):.1f}" y="{ty:.1f}" {f} font-size="20" font-weight="700" fill="{colr}" text-anchor="middle">{"金叉" if up else "死叉"} {t(i)[:5]}</text>')
    o.append("</svg>")
    open(svg, "w").write("\n".join(o))
    print(f"SVG {svg}")
