#!/usr/bin/env python3
"""合併 Fugle 歷史 K(不含今天)與今天盤中 K。
用法: python3 -I combine.py <historical.json> <intraday.json> <out.json>
盤中檔抓不到(非交易日、尚未開盤)時只用歷史。歷史抓不到就報錯結束。"""
import json, sys

hist_p, intra_p, out_p = sys.argv[1:4]
try:
    h = json.load(open(hist_p))
except Exception as e:
    sys.exit(f"資料錯誤: 讀不到歷史 K {hist_p}: {e}")
if not isinstance(h, dict) or not h.get("data"):
    sys.exit(f"資料錯誤: 歷史 K 沒有資料(Fugle 回應: {str(h)[:200]})")
try:
    t = json.load(open(intra_p))
    extra = t.get("data", []) if isinstance(t, dict) else []
    extra = [b for b in extra if isinstance(b, dict) and b.get("date")] if isinstance(extra, list) else []
except Exception:
    extra = []
h["data"] = [b for b in h["data"] if isinstance(b, dict) and isinstance(b.get("date"), str)]
if not h["data"]:
    sys.exit("資料錯誤: 歷史 K 沒有有效的 K 棒")
seen = {b["date"] for b in h["data"]}
h["data"] = h["data"] + [b for b in extra if b["date"] not in seen]
json.dump(h, open(out_p, "w"))
