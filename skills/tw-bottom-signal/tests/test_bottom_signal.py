#!/usr/bin/env python3
"""tw-bottom-signal 回歸測試(只用標準函式庫)。
執行: python3 -I tests/test_bottom_signal.py
fixture: Fugle 加權指數 30/60 分 K,2026-10-01 ~ 2026-11-16(歷史 K,不含盤中)。
規則依 Gg 2026-11-17 確認:①D<20 ②背離(前低 D<20、後低 D<30)③GC D<50 ④⑤GC 後看當下這根 ⑥60 分 K 確認。"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(HERE, "..", "scripts")
SCRIPT = os.path.join(SCRIPTS, "bottom_signal.py")
F60 = os.path.join(HERE, "fixtures", "ix0001_60m_20261001_1116.json")
F30 = os.path.join(HERE, "fixtures", "ix0001_30m_20261001_1116.json")
TMP = tempfile.gettempdir() if os.access(tempfile.gettempdir(), os.W_OK) else HERE

def run(*a):
    return subprocess.run([sys.executable, "-I", SCRIPT, *a], capture_output=True, text=True, check=True).stdout

fails = 0
def check(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

# 0. 13:30 集合競價 K 棒併入 13:00(合併後與 Fugle 60 分 K 一致)
o = run(F30, F60)
check("13:30 併入 13:00", o.startswith("【30分K】11/16 13:00 收 41,040.08") and "K 4.6 / D 9.0" in o)

# 1. 11/16 收盤:只到 ① 鈍化,② 沒有,後面不判斷;60 分 K 不做確認
check("11/16 STAGE 1/5", "① 低檔鈍化 D<20: 有" in o and "② 底部背離: 沒有" in o
      and "③ 黃金交叉 D<50: ⏸" in o and "STAGE 1/5" in o and "⑥ 60 分 K 確認: ⏸" in o)

# 2. 11/06 收盤:背離 11/04→11/06、GC 11/06 10:00 D18.3;20MA 與壓力線當下未站上 → 3/5,60 分 K 也 3/5
o = run(F30, F60, "--asof", "2026-11-06 13:30")
check("11/06 背離", "前低 11/04 12:00 41,856(D9.5)→ 後低 11/06 09:00 37,837(D15.3)" in o)
check("11/06 GC D<50", "③ 黃金交叉 D<50: 有 ✅ 11/06 10:00 K24.5 上穿 D18.3" in o)
check("11/06 30分 STAGE 3/5", o.split("⑥")[0].strip().endswith("STAGE 3/5"))
check("11/06 60分確認 3/5", "⑥ 60 分 K 確認(30 分 K 已到黃金交叉)" in o and o.strip().endswith("STAGE 3/5"))

# 3. 11/09 收盤:30 分 K 5/5(當下站上 MA20 與壓力線),60 分 K 4/5
o = run(F30, F60, "--asof", "2026-11-09 13:30")
p30, p60 = o.split("⑥")
check("11/09 20MA 當下站上", "④ 突破 20MA: 有 ✅ 當下收 41,662 > MA20 40,821" in p30)
check("11/09 壓力線當下站上", "⑤ 突破下降壓力線: 有 ✅ 當下收 41,662 > 線 41,089" in p30)
check("11/09 30分 5/5、60分 4/5", "STAGE 5/5" in p30 and p60.strip().endswith("STAGE 4/5"))

# 4. 跌回就不算:11/13 09:00 曾站上 MA20、收盤跌回 → 在這之前的流程本來就沒到 ③,改測 ④ 的「當下」語意:
#    11/09 13:00 之後 11/10 13:00 背離前低已出 4 天範圍 → 回到 1/5(整組型態要在回看範圍內)
o = run(F30, F60, "--asof", "2026-11-10 13:30")
check("超出 4 天回看範圍就不算", "STAGE 1/5" in o.split("⑥")[0])

# 5. 不偷看未來:截到 11/06 10:00,11/06 09:00 低點還沒有右邊 3 根,背離不能成立
o = run(F30, F60, "--asof", "2026-11-06 10:00")
check("背離需等右邊 3 根確認", "② 底部背離: 沒有" in o)

# 6. 有到 ② 才畫圖,只有 ① 不畫
svg = os.path.join(TMP, "bs_test.svg")
o = run(F30, F60, "--svg", svg)
check("STAGE 1 不畫圖", "SVG" not in o and not os.path.exists(svg))
o = run(F30, F60, "--asof", "2026-11-09 13:30", "--svg", svg)
check("STAGE 5 畫圖", "SVG" in o and os.path.exists(svg) and "60分K STAGE 4/5" in open(svg).read())
if os.path.exists(svg): os.remove(svg)

# 6b. 11/18:背離低點那根(10:00)同時黃金交叉也算 → STAGE 3;並列出水平壓力線、前波高點(Gg 2026-11-18)
F30b = os.path.join(HERE, "fixtures", "ix0001_30m_to_20261118.json")
F60b = os.path.join(HERE, "fixtures", "ix0001_60m_to_20261118.json")
o = run(F30b, F60b, "--asof", "2026-11-18 11:30")
p30 = o.split("⑥")[0]
check("11/18 背離 11/17→11/18", "前低 11/17 09:00 39,786(D10.4)→ 後低 11/18 10:00 39,261(D25.8)" in p30)
check("11/18 低點那根交叉算 ③", "③ 黃金交叉 D<50: 有 ✅ 11/18 10:00 K27.8 上穿 D25.8" in p30 and "STAGE 3/5" in p30)
check("11/18 水平壓力線 40,938", "水平壓力線(最近反彈高點): 11/18 09:00 40,938" in p30)
check("11/18 前波高點 44,525", "前波高點(10 日內最高): 11/12 10:00 44,525" in p30)
svg2 = os.path.join(TMP, "bs_test2.svg")
o = run(F30b, F60b, "--asof", "2026-11-18 11:30", "--svg", svg2)
s = open(svg2).read() if os.path.exists(svg2) else ""
check("11/18 圖有兩條水平線", "前波高點 44,525" in s and "水平壓力 40,938" in s)
if os.path.exists(svg2): os.remove(svg2)

# 7. 抓不到資料時要明確報錯
bad = os.path.join(TMP, "bad_fugle.json")
try:
    open(bad, "w").write('{"statusCode":401,"message":"Unauthorized"}')
    r = subprocess.run([sys.executable, "-I", SCRIPT, bad], capture_output=True, text=True)
    check("資料錯誤訊息", r.returncode != 0 and "資料錯誤" in r.stderr and "Traceback" not in r.stderr)
finally:
    if os.path.exists(bad): os.remove(bad)

# 8. combine.py:歷史 + 盤中合併,盤中抓不到時只用歷史
out = os.path.join(TMP, "bs_comb.json"); intra = os.path.join(TMP, "bs_intra.json")
try:
    open(intra, "w").write(json.dumps({"data": [{"date": "2026-11-17T09:00:00.000+08:00", "open": 40546.64,
        "high": 40546.64, "low": 39786.45, "close": 40000.0, "volume": 1}]}))
    subprocess.run([sys.executable, "-I", os.path.join(SCRIPTS, "combine.py"), F30, intra, out], check=True)
    d = json.load(open(out))["data"]
    check("combine 接上盤中", len(d) == 301 and max(b["date"] for b in d).startswith("2026-11-17T09:00"))
    open(intra, "w").write('{"statusCode":404}')
    subprocess.run([sys.executable, "-I", os.path.join(SCRIPTS, "combine.py"), F30, intra, out], check=True)
    check("combine 盤中抓不到只用歷史", len(json.load(open(out))["data"]) == 300)
finally:
    for p in (out, intra):
        if os.path.exists(p): os.remove(p)

sys.exit(1 if fails else 0)
