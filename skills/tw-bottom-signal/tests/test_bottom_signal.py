#!/usr/bin/env python3
"""tw-bottom-signal 回歸測試(只用標準函式庫)。
執行: python3 -I tests/test_bottom_signal.py
fixture: Fugle 加權指數 30/60 分 K,2026-10-01 ~ 2026-11-16。"""
import os, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "bottom_signal.py")
F60 = os.path.join(HERE, "fixtures", "ix0001_60m_20261001_1116.json")
F30 = os.path.join(HERE, "fixtures", "ix0001_30m_20261001_1116.json")

def run(*a):
    return subprocess.run([sys.executable, "-I", SCRIPT, *a], capture_output=True, text=True, check=True).stdout

fails = 0
def check(name, cond):
    global fails
    print(("PASS " if cond else "FAIL ") + name)
    fails += 0 if cond else 1

# 1. 11/16 收盤:30、60 分 K 都沒有任何訊號(大跌 6% 收最低)
o = run(F30, "30分K")
check("11/16 30分K 0/4", "HITS 0/4" in o and "K 3.0 / D 6.6" in o)
o = run(F60, "60分K")
check("11/16 60分K 0/4", "HITS 0/4" in o and "K 8.0 / D 20.3" in o)

# 2. 11/10 10:00 60 分 K:背離、壓力線、20MA 成立;交叉在 D=18.2,D>=20 規則下不算
o = run(F60, "60分K", "--asof", "2026-11-10 10:00", "--lookback", "20")
check("11/10 60分K 背離", "1. D值底部背離: 有" in o and "37,837(D14.8)" in o)
check("11/10 60分K 交叉 D18.2 不算(dmin 20)", "2. D≥20 黃金交叉: 沒有" in o)
check("11/10 60分K 壓力線", "3. 突破下降壓力線: 有" in o and "收 42,956 站上壓力線 41,840" in o)
check("11/10 60分K 20MA", "4. 突破 20MA: 有" in o and "11/09 10:00 收 42,077" in o)
check("11/10 60分K 3/4", "HITS 3/4" in o)

# 3. dmin 0 時交叉成立(範例圖用)
o = run(F60, "60分K", "--asof", "2026-11-10 10:00", "--lookback", "20", "--dmin", "0")
check("dmin 0 交叉 11/06 10:00", "11/06 10:00 K25.0 上穿 D18.2" in o and "HITS 4/4" in o)

# 4. 無未來函數:截到 11/06 10:30 時,11/06 09:00 的低點還沒有右邊 3 根,背離不能成立
o = run(F60, "60分K", "--asof", "2026-11-06 10:00", "--lookback", "20")
check("背離需等右邊 3 根確認", "1. D值底部背離: 沒有" in o)

sys.exit(1 if fails else 0)
