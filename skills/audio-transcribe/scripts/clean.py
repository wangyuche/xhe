#!/usr/bin/env python3
"""Step 3: clean a whisper.cpp .txt transcript.
Usage: python3 -I clean.py <in.txt> <out.txt>

whisper hallucinates during silence / music / crosstalk:
  - filler-only lines (對、嗯、謝謝、好、你好 ...) repeated hundreds of times
  - the same sentence looping (e.g. one line 160x in a row)
  - stray YouTube-style lines (請不吝點贊 訂閱 轉發 ..., 字幕由 ... 提供)
This script drops filler-only lines, collapses consecutive duplicates, removes known
hallucination phrases, and prints stats so the caller can judge transcript quality."""
import re, sys
from collections import Counter

FILLER = {"對", "嗯", "好", "是", "謝謝", "你好", "對對對", "對對", "OK", "ok", "那", "然後", "對啊", "好的"}
HALLU = re.compile(r"(點贊|点赞|訂閱|订阅|轉發|转发|打賞|打赏|字幕由|字幕提供|明鏡與點點|明镜与点点)")

src, dst = sys.argv[1], sys.argv[2]
lines = [l.strip() for l in open(src, encoding="utf-8")]
raw = [l for l in lines if l]
counts = Counter(raw)
out, dropped_filler, dropped_dup, dropped_hallu = [], 0, 0, 0
for l in raw:
    core = re.sub(r"[\s,，。.、!！?？]+", "", l)
    if core in FILLER or re.fullmatch(r"(對|好|嗯|謝謝)+", core or "x"):
        dropped_filler += 1; continue
    if HALLU.search(l):
        dropped_hallu += 1; continue
    if out and out[-1] == l:
        dropped_dup += 1; continue
    # 同一字元重複很多次(例如「法法法法法法法」)壓成 3 個
    l = re.sub(r"(.)\1{5,}", r"\1\1\1", l)
    out.append(l)
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
loops = [(l, c) for l, c in counts.most_common(5) if c >= 20]
print(f"lines_in={len(raw)} lines_out={len(out)} filler={dropped_filler} dup={dropped_dup} hallu={dropped_hallu}")
for l, c in loops:
    print(f"LOOP {c}x: {l[:40]}")
if loops and max(c for _, c in loops) >= 100:
    print("WARN 有嚴重重複迴圈,可能有段落沒辨識出來;確認轉錄時有加 -mc 0")
