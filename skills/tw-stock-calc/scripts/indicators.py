#!/usr/bin/env python3
"""台股技術指標計算(只用標準函式庫,讀 stdin、寫 stdout,不寫任何檔案)。

用法:
  { curl -s <月份1>; curl -s <月份2>; ... } | python3 indicators.py

stdin 可以是一個或多個串接的 JSON,支援:
  - 臺灣證券交易所 STOCK_DAY:{"stat":"OK","fields":[...],"data":[...]}
  - 櫃買中心 tradingStock:{"tables":[{"fields":[...],"data":[...]}]}
  - FinMind TaiwanStockPrice:{"data":[{"date","open","max","min","close","Trading_Volume"}]}
  - 已整理好的陣列:[{"date","open","high","low","close","volume"}]

日期重複時保留最後一筆,依日期排序後計算。演算法見 SKILL.md。
"""
import json
import sys

# ---------- 解析 ----------

def _num(s):
    if s is None:
        return None
    if isinstance(s, (int, float)):
        return float(s)
    s = str(s).replace(",", "").strip()
    if s in ("", "--", "---", "X", "除權息", "除息", "除權"):
        return None
    try:
        return float(s)
    except ValueError:
        return None


def _date(s):
    """'115/11/03' 民國 或 '2026-11-03' / '20261103' → 'YYYY-MM-DD'。"""
    s = str(s).strip().replace("＊", "").replace("*", "")
    if "/" in s:
        y, m, d = s.split("/")
        y = int(y)
        if y < 1911:
            y += 1911
        return f"{y:04d}-{int(m):02d}-{int(d):02d}"
    if len(s) == 8 and s.isdigit():
        return f"{s[:4]}-{s[4:6]}-{s[6:]}"
    return s[:10]


def _field_index(fields, *keys):
    for i, f in enumerate(fields):
        f = "".join(str(f).split())  # 櫃買中心欄位名有空格,例如「日 期」
        for k in keys:
            if k in f:
                return i
    return None


def _rows_from_table(fields, data):
    i_d = _field_index(fields, "日期")
    i_o = _field_index(fields, "開盤")
    i_h = _field_index(fields, "最高")
    i_l = _field_index(fields, "最低")
    i_c = _field_index(fields, "收盤")
    i_v = _field_index(fields, "成交股數", "成交張數", "成交仟股")
    if None in (i_d, i_h, i_l, i_c):
        raise ValueError(f"無法辨識欄位:{fields}")
    out = []
    for r in data:
        out.append({
            "date": _date(r[i_d]),
            "open": _num(r[i_o]) if i_o is not None else None,
            "high": _num(r[i_h]),
            "low": _num(r[i_l]),
            "close": _num(r[i_c]),
            "volume": _num(r[i_v]) if i_v is not None else None,
        })
    return out


def parse_obj(obj):
    if isinstance(obj, list):
        return [{
            "date": _date(r["date"]), "open": _num(r.get("open")),
            "high": _num(r.get("high")), "low": _num(r.get("low")),
            "close": _num(r.get("close")), "volume": _num(r.get("volume")),
        } for r in obj]
    if "stat" in obj and str(obj.get("stat")).upper() != "OK":  # 查無資料或錯誤(櫃買中心回小寫 ok)
        return []
    if "fields" in obj and "data" in obj:  # TWSE STOCK_DAY
        return _rows_from_table(obj["fields"], obj["data"])
    if "tables" in obj:  # TPEx
        rows = []
        for t in obj["tables"]:
            if t.get("fields") and t.get("data"):
                rows += _rows_from_table(t["fields"], t["data"])
        return rows
    if "data" in obj and isinstance(obj["data"], list):  # FinMind
        return [{
            "date": _date(r["date"]), "open": _num(r.get("open")),
            "high": _num(r.get("max")), "low": _num(r.get("min")),
            "close": _num(r.get("close")), "volume": _num(r.get("Trading_Volume")),
        } for r in obj["data"]]
    raise ValueError("無法辨識的 JSON 格式")


def parse_stream(text):
    dec = json.JSONDecoder()
    i, n, objs = 0, len(text), []
    while i < n:
        while i < n and text[i].isspace():
            i += 1
        if i >= n:
            break
        obj, i = dec.raw_decode(text, i)
        objs.append(obj)
    rows = {}
    for o in objs:
        for r in parse_obj(o):
            rows[r["date"]] = r
    # 沒有成交(收盤為空)的日子不納入計算
    out = [rows[d] for d in sorted(rows)
           if rows[d]["close"] is not None and rows[d]["high"] is not None and rows[d]["low"] is not None]
    return out

# ---------- 指標 ----------

def sma(values, n):
    out = [None] * len(values)
    for i in range(n - 1, len(values)):
        out[i] = sum(values[i - n + 1:i + 1]) / n
    return out


def ema(values, n):
    a = 2 / (n + 1)
    out = []
    for i, v in enumerate(values):
        out.append(v if i == 0 else out[-1] * (1 - a) + v * a)
    return out


def kd(high, low, close, n=9):
    K = [None] * len(close)
    D = [None] * len(close)
    pk = pd = 50.0
    for i in range(n - 1, len(close)):
        hh = max(high[i - n + 1:i + 1])
        ll = min(low[i - n + 1:i + 1])
        rsv = 50.0 if hh == ll else (close[i] - ll) / (hh - ll) * 100
        k = pk * 2 / 3 + rsv / 3
        d = pd * 2 / 3 + k / 3
        K[i], D[i] = k, d
        pk, pd = k, d
    return K, D


def rsi(close, n=14):
    out = [None] * len(close)
    if len(close) <= n:
        return out
    ch = [close[i] - close[i - 1] for i in range(1, len(close))]
    ag = sum(max(c, 0) for c in ch[:n]) / n
    al = sum(max(-c, 0) for c in ch[:n]) / n

    def val(g, l):
        if l == 0:
            return 100.0 if g > 0 else 50.0
        return 100 - 100 / (1 + g / l)

    out[n] = val(ag, al)
    for j in range(n, len(ch)):
        ag = (ag * (n - 1) + max(ch[j], 0)) / n
        al = (al * (n - 1) + max(-ch[j], 0)) / n
        out[j + 1] = val(ag, al)
    return out


def macd(close, fast=12, slow=26, sig=9):
    e1, e2 = ema(close, fast), ema(close, slow)
    dif = [a - b for a, b in zip(e1, e2)]
    sl = ema(dif, sig)
    hist = [a - b for a, b in zip(dif, sl)]
    return dif, sl, hist


def swing_points(rows, lookback=60, w=3):
    """近 lookback 筆中,左右各 w 筆內的最高/最低點。"""
    seg = rows[-lookback:]
    highs, lows = [], []
    for i in range(w, len(seg) - w):
        win = seg[i - w:i + w + 1]
        if seg[i]["high"] == max(r["high"] for r in win):
            highs.append({"date": seg[i]["date"], "price": seg[i]["high"]})
        if seg[i]["low"] == min(r["low"] for r in win):
            lows.append({"date": seg[i]["date"], "price": seg[i]["low"]})
    return highs, lows


def volume_profile(rows, lookback=60, bins=20):
    """近 lookback 筆以收盤價分箱、成交量加總,回傳量最大的價格區間。"""
    seg = [r for r in rows[-lookback:] if r["volume"]]
    if not seg:
        return None
    lo = min(r["low"] for r in seg)
    hi = max(r["high"] for r in seg)
    if hi == lo:
        return {"low": lo, "high": hi, "volume_share": 1.0}
    step = (hi - lo) / bins
    acc = [0.0] * bins
    for r in seg:
        b = min(int((r["close"] - lo) / step), bins - 1)
        acc[b] += r["volume"]
    b = max(range(bins), key=lambda i: acc[i])
    return {"low": round(lo + b * step, 2), "high": round(lo + (b + 1) * step, 2),
            "volume_share": round(acc[b] / sum(acc), 4)}


def r2(x):
    return None if x is None else round(x, 2)


def compute(rows):
    if len(rows) < 120:
        warn = f"資料只有 {len(rows)} 筆,少於規格要求的 120 筆"
    else:
        warn = None
    c = [r["close"] for r in rows]
    h = [r["high"] for r in rows]
    l = [r["low"] for r in rows]
    v = [r["volume"] for r in rows]
    ma5, ma20, ma60 = sma(c, 5), sma(c, 20), sma(c, 60)
    K, D = kd(h, l, c)
    R = rsi(c)
    dif, sig, hist = macd(c)
    vol_ratio = None
    if len(v) >= 20 and all(x is not None for x in v[-20:]):
        avg20 = sum(v[-20:]) / 20
        vol_ratio = v[-1] / avg20 if avg20 else None
    highs, lows = swing_points(rows)
    last = len(rows) - 1
    seg10 = rows[-10:]
    avg_range_10d = sum(r["high"] - r["low"] for r in seg10) / len(seg10)
    return {
        "start": rows[0]["date"], "end": rows[-1]["date"], "count": len(rows),
        "adjusted": False, "warning": warn,
        "latest": {
            "date": rows[-1]["date"], "close": c[-1], "volume": v[-1],
            "ma5": r2(ma5[last]), "ma20": r2(ma20[last]), "ma60": r2(ma60[last]),
            "k": r2(K[last]), "d": r2(D[last]), "rsi14": r2(R[last]),
            "dif": r2(dif[last]), "macd": r2(sig[last]), "hist": r2(hist[last]),
            "volume_ratio_20d": r2(vol_ratio),
            "avg_range_10d": r2(avg_range_10d),
        },
        "previous": {
            "date": rows[-2]["date"] if len(rows) > 1 else None,
            "k": r2(K[last - 1]) if last >= 1 else None,
            "d": r2(D[last - 1]) if last >= 1 else None,
            "dif": r2(dif[last - 1]) if last >= 1 else None,
            "macd": r2(sig[last - 1]) if last >= 1 else None,
        },
        "levels": {
            "swing_highs_60": highs[-5:], "swing_lows_60": lows[-5:],
            "ma20": r2(ma20[last]), "ma60": r2(ma60[last]),
            "volume_dense_zone_60": volume_profile(rows),
        },
        "notes": "量能倍數 = 最後一筆成交量 ÷ 含最後一筆在內的近 20 筆平均;"
                 "前波高低點 = 近 60 筆中左右各 3 筆內的極值;"
                 "成交密集區 = 近 60 筆收盤價分 20 箱、成交量加總最大的一箱;"
                 "近 10 日平均振幅 = 近 10 筆(最高價 − 最低價)的平均。",
    }


def main():
    try:
        rows = parse_stream(sys.stdin.read())
    except ValueError as e:
        print(json.dumps({"error": str(e)}, ensure_ascii=False))
        sys.exit(1)
    if not rows:
        print(json.dumps({"error": "沒有可用的日線資料"}, ensure_ascii=False))
        sys.exit(1)
    print(json.dumps(compute(rows), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
