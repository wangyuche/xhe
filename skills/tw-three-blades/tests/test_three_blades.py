#!/usr/bin/env python3
"""tw-three-blades 回歸測試(只用標準函式庫)。
執行: python3 -I tests/test_three_blades.py
fixture: Fugle 加權指數 60 分 K,2026-07-01 ~ 2026-11-27(510 根,每天 09/10/11/12/13 點 5 根)。"""
import json, os, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "three_blades.py")
F60 = os.path.join(HERE, "fixtures", "ix0001_60m_20260701_1127.json")
TMP = tempfile.gettempdir() if os.access(tempfile.gettempdir(), os.W_OK) else HERE

def run(*a):
    return subprocess.run([sys.executable, "-I", SCRIPT, *a], capture_output=True, text=True)

fails = 0
def check(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

# 1. 11/27 收盤:空頭排列、小橘斜率負(11/03 11:00 轉負)、最近藍綠死亡交叉 11/17 12:00
o = run(F60).stdout
check("11/27 三條均線", "小藍 20MA 39,066" in o and "小綠 60MA 39,794" in o and "小橘 240MA 44,847" in o)
check("11/27 空頭排列", "排列:空頭排列" in o)
check("11/27 空方環境、小橘斜率轉負", "① 方向(小橘斜率):空方環境(小橘斜率 11/03 11:00 由正轉負)" in o)
check("11/27 藍綠死亡交叉", "② 藍綠交叉:最近一次 11/17 12:00 死亡交叉" in o)
check("11/27 結論", "結論:空方環境,條件未齊" in o)

# 2. 11/13 13:00:藍綠剛黃金交叉,小橘斜率為負 → 逆勢反彈
o = run(F60, "--asof", "2026-11-13 13:00").stdout
check("11/13 黃金交叉、空方環境逆勢", "11/13 13:00 黃金交叉" in o and "屬逆勢反彈" in o)

# 3. 斜率根數可調
o = run(F60, "--slope-n", "1").stdout
check("--slope-n 1", "斜率=比 1 根前" in o)

# 4. 資料不夠 240 根要報錯
r = run(F60, "--asof", "2026-08-15 13:00")
check("資料不足報錯", r.returncode != 0 and "至少要" in r.stderr and "Traceback" not in r.stderr)

# 5. 抓不到資料時要明確報錯
bad = os.path.join(TMP, "tb_bad.json")
try:
    open(bad, "w").write('{"statusCode":401,"message":"Unauthorized"}')
    r = run(bad)
    check("資料錯誤訊息", r.returncode != 0 and "資料錯誤" in r.stderr and "Traceback" not in r.stderr)
finally:
    if os.path.exists(bad): os.remove(bad)

# 6. 畫圖
svg = os.path.join(TMP, "tb_test.svg")
o = run(F60, "--svg", svg).stdout
s = open(svg).read() if os.path.exists(svg) else ""
check("SVG 有三條均線與交叉標記", "SVG" in o and "小橘 240MA 44,847" in s and "死叉 11/17" in s)
if os.path.exists(svg): os.remove(svg)

# 7. 低價股保留小數
low = os.path.join(TMP, "tb_low.json")
try:
    d = json.load(open(F60))
    for b in d["data"]:
        for k in ("open", "high", "low", "close"): b[k] = round(b[k] / 600, 2)
    json.dump(d, open(low, "w"))
    o = run(low).stdout
    check("低價保留小數", "小藍 20MA 65.1" in o)
finally:
    if os.path.exists(low): os.remove(low)

sys.exit(1 if fails else 0)
