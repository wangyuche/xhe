#!/usr/bin/env python3
"""Step 3: clean a whisper.cpp .txt transcript.
Usage: python3 -I clean.py <in.txt> <out.txt>

whisper hallucinates during silence / music / crosstalk:
  - filler-only lines (對、嗯、謝謝、好、你好 ...) repeated hundreds of times
  - the same sentence looping (e.g. one line 160x in a row)
  - stray YouTube-style lines (請不吝點贊 訂閱 轉發 ..., 字幕由 ... 提供)
This script drops filler-only lines, collapses consecutive duplicates, removes known
hallucination phrases (only whole channel-promo lines, never a line that merely mentions 訂閱/轉發), and prints stats so the caller can judge transcript quality."""
import re, sys
from collections import Counter

FILLER = {"對", "嗯", "好", "是", "謝謝", "你好", "對對對", "對對", "OK", "ok", "那", "然後", "對啊", "好的"}
# 幻覺句只認「整句都是頻道宣傳」的樣子,不能只因出現「訂閱」「轉發」就刪(例如「訂閱制營收年增 30%」是正常內容):
#   STRONG:這些片語本身就是頻道宣傳 / 字幕組署名
#   PROMO:把宣傳動作與客套字拿掉後幾乎不剩東西(「請訂閱」「記得按讚訂閱」「感謝打賞」)才算;
#          「直播打賞與訂閱收入占比 20%」拿掉後還剩「直播收入占比20%」,保留
STRONG = re.compile(r"明鏡與點點|明镜与点点|字幕由.{0,20}提供|字幕提供|請不吝|请不吝"
                    r"|(訂閱|订阅)(我的|我們的|我们的|本)?(頻道|频道)|(開啟|开启|打開|打开)小(鈴鐺|铃铛)")
CTA = re.compile(r"點贊|点赞|按讚|按赞|按個讚|點個讚|訂閱|订阅|轉發|转发|分享|打賞|打赏|小鈴鐺|小铃铛|收藏|關注|关注")
POLITE = re.compile(r"請|请|記得|记得|歡迎|欢迎|感謝|感谢|謝謝|谢谢|支持|多多|大家|幫忙|帮忙|一下|開啟|开启|打開|打开"
                    r"|我的|我們的|我们的|本|頻道|频道|欄目|栏目|和|與|与|及|並|并|加|按|喔|哦|吧|啊|呀|哈|的|一起|喜歡|喜欢")


def is_hallucination(line):
    if STRONG.search(line):
        return True
    core = re.sub(r"[\s,，。.、!！?？~～]+", "", line)
    if not CTA.search(core):
        return False
    return len(POLITE.sub("", CTA.sub("", core))) <= 1


src, dst = sys.argv[1], sys.argv[2]
lines = [l.strip() for l in open(src, encoding="utf-8")]
raw = [l for l in lines if l]
counts = Counter(raw)
out, dropped_filler, dropped_dup, dropped_hallu = [], 0, 0, 0
for l in raw:
    core = re.sub(r"[\s,，。.、!！?？]+", "", l)
    if core in FILLER or re.fullmatch(r"(對|好|嗯|謝謝)+", core or "x"):
        dropped_filler += 1; continue
    if is_hallucination(l):
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
