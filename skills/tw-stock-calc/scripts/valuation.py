#!/usr/bin/env python3
"""台股合理價估算(只用標準函式庫,讀 stdin、寫 stdout,不寫任何檔案)。

用法:
  curl -s '<FinMind TaiwanStockPER 近 5 年>' | python3 valuation.py \
      --eps4q 45.2 --bvps 210.5 --dividend 18 --price 1475

stdin:FinMind TaiwanStockPER 回應 {"data":[{"date","PER","PBR","dividend_yield"}]}。
參數:近 4 季 EPS 合計、最新每股淨值、近一年現金股利(最近一個完整盈餘年度的合計)、目前股價。
沒有的數字就不要給,對應方法會標為不適用。
FinMind 回錯誤(例如 402 額度用完)時輸出 error、結束碼 1(資料缺口,不是不適用)。沒給 --bvps 但有 --price 時,
每股淨值 = 目前股價 ÷ 最新一筆 PBR(--price 須為該筆資料同日收盤價)。

判定(多數決):股價高於過半適用方法的上限 → 偏貴;低於過半適用方法的下限 → 偏便宜;
其餘 → 合理。

百分位定義:排除 ≤0 與空值後排序,用線性內插(與 numpy 預設、
statistics.quantiles(method="inclusive") 相同):位置 = (n−1)×p。
"""
import argparse
import json
import sys

MIN_VALID = 250


def pct(sorted_vals, p):
    n = len(sorted_vals)
    pos = (n - 1) * p
    lo = int(pos)
    hi = min(lo + 1, n - 1)
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (pos - lo)


def series(data, key):
    vals = []
    for r in data:
        v = r.get(key)
        try:
            v = float(v)
        except (TypeError, ValueError):
            continue
        if v > 0:
            vals.append(v)
    return sorted(vals)


def method(name, vals, base, base_label, invert=False):
    res = {"method": name, "valid_count": len(vals)}
    if base is None:
        res.update(applicable=False, reason=f"無{base_label}資料")
        return res
    if base <= 0:
        res.update(applicable=False, reason=f"{base_label} ≤ 0({base})")
        return res
    if len(vals) < MIN_VALID:
        res.update(applicable=False, reason=f"有效筆數 {len(vals)} < {MIN_VALID}")
        return res
    p25, p75 = pct(vals, 0.25), pct(vals, 0.75)
    if invert:  # 殖利率法:股利 ÷ 殖利率(%),P75 對應低價、P25 對應高價
        low, high = base / (p75 / 100), base / (p25 / 100)
    else:
        low, high = base * p25, base * p75
    res.update(applicable=True, base=base, p25=round(p25, 2), p75=round(p75, 2),
               fair_low=round(low, 2), fair_high=round(high, 2))
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eps4q", type=float)
    ap.add_argument("--bvps", type=float)
    ap.add_argument("--dividend", type=float)
    ap.add_argument("--price", type=float)
    a = ap.parse_args()

    try:
        obj = json.loads(sys.stdin.read() or "{}")
    except ValueError as e:
        print(json.dumps({"error": f"無法解析 TaiwanStockPER 回應:{e}"}, ensure_ascii=False))
        sys.exit(1)
    if not isinstance(obj, dict):
        print(json.dumps({"error": "TaiwanStockPER 回應格式不符"}, ensure_ascii=False))
        sys.exit(1)
    status = obj.get("status")
    # 沒有 status 也沒有 data、msg 又不是 success(例如代理回的 {"msg":"rate limited"})也算錯誤
    no_data_msg = status is None and "data" not in obj and obj.get("msg") not in (None, "success")
    if "error" in obj or status not in (None, 200) or no_data_msg:
        # FinMind 錯誤(402 = 額度用完、400 參數錯、401/403 token 問題):是資料缺口,不是「不適用」
        msg = obj.get("msg") or obj.get("error") or ""
        err = {"error": ("FinMind 額度用完(402),估值資料缺口;設定 FINMIND_TOKEN 或稍後重試"
                         if status == 402 else f"FinMind 回應錯誤(status {status}):{msg}"),
               "status": status, "api_message": msg}
        print(json.dumps(err, ensure_ascii=False))
        sys.exit(1)
    data = obj.get("data") or []
    bvps, bvps_note = a.bvps, None
    if bvps is None and a.price is not None and data:
        last = max((r for r in data if r.get("date")), key=lambda r: r["date"], default=None)
        try:
            pbr = float(last.get("PBR")) if last else 0
        except (TypeError, ValueError):
            pbr = 0
        if pbr > 0:
            bvps = round(a.price / pbr, 2)
            bvps_note = f"每股淨值由 {a.price} ÷ {last['date']} PBR {pbr} 推得"
    dates = sorted(r["date"] for r in data if r.get("date"))
    out = {"source": "FinMind TaiwanStockPER",
           "start": dates[0] if dates else None, "end": dates[-1] if dates else None,
           "rows": len(data)}
    if not data:
        out["methods"] = [
            {"method": m, "applicable": False, "reason": "TaiwanStockPER 無資料"}
            for m in ("本益比區間", "股價淨值比", "殖利率法")]
    else:
        out["methods"] = [
            method("本益比區間", series(data, "PER"), a.eps4q, "近 4 季 EPS"),
            method("股價淨值比", series(data, "PBR"), bvps, "每股淨值"),
            method("殖利率法", series(data, "dividend_yield"), a.dividend, "近一年現金股利",
                   invert=True),
        ]
        if bvps_note:
            out["methods"][1]["note"] = bvps_note
    ok = [m for m in out["methods"] if m.get("applicable")]
    if ok:
        lo = min(m["fair_low"] for m in ok)
        hi = max(m["fair_high"] for m in ok)
        out["fair_range"] = {"low": lo, "high": hi,
                             "rule": "各適用方法合理價下限取最小、上限取最大(只用於顯示,判定用多數決)"}
        if a.price is not None:
            above = [m["method"] for m in ok if a.price > m["fair_high"]]
            below = [m["method"] for m in ok if a.price < m["fair_low"]]
            for m in ok:
                m["position"] = ("高於上限" if m["method"] in above
                                 else "低於下限" if m["method"] in below else "區間內")
            if len(above) * 2 > len(ok):
                verdict = "偏貴"
            elif len(below) * 2 > len(ok):
                verdict = "偏便宜"
            else:
                verdict = "合理"
            out["price"] = a.price
            out["verdict"] = verdict
            out["verdict_rule"] = (f"多數決:{len(ok)} 種適用方法中,股價高於上限 {len(above)} 種、"
                                   f"低於下限 {len(below)} 種;過半高於上限為偏貴、過半低於下限為偏便宜")
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
