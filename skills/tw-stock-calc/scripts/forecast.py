#!/usr/bin/env python3
"""短期(1–2 週)預估區間的固定公式(只用標準函式庫,不讀檔、不寫檔)。

用法:
  python3 forecast.py --supports 1450 1430 --resistances 1500 1515 --avg-range 35.2

公式:
  區間下限 = 最低支撐 − 0.5 × 近 10 日平均振幅
  區間上限 = 最高壓力 + 0.5 × 近 10 日平均振幅
近 10 日平均振幅取自 indicators.py 輸出的 latest.avg_range_10d。
支撐必須都低於壓力,否則回報 error(結束碼 1)。
"""
import argparse
import json
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--supports", type=float, nargs="+", required=True)
    ap.add_argument("--resistances", type=float, nargs="+", required=True)
    ap.add_argument("--avg-range", type=float, required=True)
    a = ap.parse_args()
    s_lo, r_hi = min(a.supports), max(a.resistances)
    if max(a.supports) >= min(a.resistances):
        print(json.dumps({"error": f"支撐 {sorted(a.supports)} 與壓力 {sorted(a.resistances)} 重疊:"
                                   "每個支撐都必須低於每個壓力"}, ensure_ascii=False))
        sys.exit(1)
    if a.avg_range < 0:
        print(json.dumps({"error": "平均振幅不可為負"}, ensure_ascii=False))
        sys.exit(1)
    half = 0.5 * a.avg_range
    print(json.dumps({
        "low": round(s_lo - half, 2), "high": round(r_hi + half, 2),
        "lowest_support": s_lo, "highest_resistance": r_hi, "avg_range_10d": a.avg_range,
        "rule": "下限 = 最低支撐 − 0.5 × 近 10 日平均振幅;上限 = 最高壓力 + 0.5 × 近 10 日平均振幅",
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
