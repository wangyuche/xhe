#!/usr/bin/env python3
"""tw-bottom-signal 回歸測試(只用標準函式庫)。
執行: python3 -I tests/test_bottom_signal.py
fixture: Fugle 加權指數 30/60 分 K,2026-10-01 ~ 2026-11-16(歷史 K,不含盤中)。
規則依 Gg 2026-11-17 確認:①D<20 ②背離(前低 D<20、後低 D<30)③GC D<50 ④⑤⑥GC 後看當下這根(⑥水平壓力區間,2026-11-19) ⑦60 分 K 確認。"""
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

# 1. 11/16 收盤:11/04→11/06 背離前低已超出 4 天,但 37,837 沒被跌破 → 保留(Gg 2026-11-27 3A),
#    ③ 11/06 交叉、⑤ 高點連線已站上 → 4/6;--keep-days 4 等於舊規則(只看 4 天)→ 只到 ① 1/6
check("11/16 背離保留 STAGE 4/6", "前低已超出回看 4 天,未跌破背離低點 37,837 所以保留" in o
      and o.split("⑦")[0].strip().endswith("STAGE 4/6"))
o = run(F30, F60, "--keep-days", "4")
check("11/16 keep-days 4 → STAGE 1/6", "① 低檔鈍化 D<20: 有" in o and "② 底部背離: 沒有" in o
      and "③ 黃金交叉 D<50: ⏸" in o and "STAGE 1/6" in o and "⑦ 60 分 K 確認: ⏸" in o)

# 2. 11/06 收盤:背離 11/04→11/06、GC 11/06 10:00 D18.3;20MA 與壓力線當下未站上 → 3/6,60 分 K 也 3/6
o = run(F30, F60, "--asof", "2026-11-06 13:30")
check("11/06 背離", "前低 11/04 12:00 41,856(D9.5)→ 後低 11/06 09:00 37,837(D15.3)" in o)
check("11/06 GC D<50", "③ 黃金交叉 D<50: 有 ✅ 11/06 10:00 K24.5 上穿 D18.3" in o)
check("11/06 30分 STAGE 3/6", o.split("⑦")[0].strip().endswith("STAGE 3/6"))
check("11/06 60分確認 3/6", "⑦ 60 分 K 確認(30 分 K 已到黃金交叉)" in o and o.strip().endswith("STAGE 3/6"))

# 3. 11/09 收盤:30 分 K 5/6(當下站上 MA20 與壓力線,未過水平壓力區間),60 分 K 4/6
o = run(F30, F60, "--asof", "2026-11-09 13:30")
p30, p60 = o.split("⑦")
check("11/09 20MA 當下站上", "④ 突破 20MA: 有 ✅ 當下收 41,662 > MA20 40,821" in p30)
check("11/09 壓力線當下站上", "⑤ 突破下降壓力線(任一條站上就算): 有 ✅" in p30
      and "高點連線:線 41,089(11/04 09:00 43,742 → 11/04 13:00 43,135)當下收 41,662 ✅ 11/09 09:30 首次站上" in p30
      and "通道上緣" not in p30)
check("11/09 30分 5/6、60分 4/6", "STAGE 5/6" in p30 and p60.strip().endswith("STAGE 4/6"))

# 4. 11/10 13:00 背離前低已出 4 天範圍:新規則保留(沒跌破 37,837);--keep-days 4 時回到舊規則 1/6
o = run(F30, F60, "--asof", "2026-11-10 13:30")
check("超出 4 天回看仍保留背離", "所以保留" in o.split("⑦")[0] and "② 底部背離: 有 ✅" in o.split("⑦")[0])
o = run(F30, F60, "--asof", "2026-11-10 13:30", "--keep-days", "4")
check("keep-days 4 超出回看就不算", "STAGE 1/6" in o.split("⑦")[0])

# 5. 不偷看未來:截到 11/06 10:00,11/06 09:00 低點還沒有右邊 3 根,背離不能成立
o = run(F30, F60, "--asof", "2026-11-06 10:00")
check("背離需等右邊 3 根確認", "② 底部背離: 沒有" in o)

# 6. 有到 ② 才畫圖,只有 ① 不畫
svg = os.path.join(TMP, "bs_test.svg")
o = run(F30, F60, "--svg", svg, "--keep-days", "4")
check("STAGE 1 不畫圖", "SVG" not in o and not os.path.exists(svg))
o = run(F30, F60, "--asof", "2026-11-09 13:30", "--svg", svg)
check("STAGE 5 畫圖", "SVG" in o and os.path.exists(svg) and "60分K STAGE 4/6" in open(svg).read())
if os.path.exists(svg): os.remove(svg)

# 6b. 11/18:背離低點那根(10:00)同時黃金交叉也算 → STAGE 3;⑥ 水平壓力區間 = 11/17、11/18 兩個反彈高點
F30b = os.path.join(HERE, "fixtures", "ix0001_30m_to_20261118.json")
F60b = os.path.join(HERE, "fixtures", "ix0001_60m_to_20261118.json")
o = run(F30b, F60b, "--asof", "2026-11-18 11:30")
p30 = o.split("⑦")[0]
check("11/18 背離 11/17→11/18", "前低 11/17 09:00 39,786(D10.4)→ 後低 11/18 10:00 39,261(D25.8)" in p30)
check("11/18 低點那根交叉算 ③", "③ 黃金交叉 D<50: 有 ✅ 11/18 10:00 K27.8 上穿 D25.8" in p30 and "STAGE 3/6" in p30)
check("11/18 水平壓力區間 ⑥", "⑥ 突破水平壓力區間: 沒有 ❌ 當下收 40,141.43,區間 40,938.2～40,945.04" in p30)
check("11/18 前波高點 44,525", "前波高點(10 日內最高): 11/12 10:00 44,525" in p30)
svg2 = os.path.join(TMP, "bs_test2.svg")
o = run(F30b, F60b, "--asof", "2026-11-18 11:30", "--svg", svg2)
s = open(svg2).read() if os.path.exists(svg2) else ""
check("11/18 圖有前波高點＋水平壓力區間", "前波高點 44,525" in s and "水平壓力區間 40,938.2～40,945.04" in s)
if os.path.exists(svg2): os.remove(svg2)

# 6b2. ⑤ 下降通道(Gg 2026-11-27 2D):給 --channel-from 才畫;下緣 低點1→背離低點,上緣平行通過兩低點間離下緣最遠的高點
o = run(F30b, "--asof", "2026-11-18 11:30", "--channel-from", "2026-11-13 09:30")
check("通道上緣站上 → ⑤ 成立(高點連線未站上)",
      "高點連線:線 40,930" in o and "❌ 差 -788" in o
      and "通道上緣:線 40,056(下緣 11/13 09:30 44,203 → 11/18 10:00 39,261,平行通過 11/18 09:00 40,938)當下收 40,141 ✅ 11/18 11:30 首次站上" in o
      and "STAGE 4/6" in o)
svg4 = os.path.join(TMP, "bs_test4.svg")
o = run(F30b, "--asof", "2026-11-18 11:30", "--channel-from", "2026-11-13 09:30", "--svg", svg4)
check("通道圖", "SVG" in o and os.path.exists(svg4) and "突破通道上緣" in open(svg4).read())
if os.path.exists(svg4): os.remove(svg4)

# 6b3. PR #41 review:--channel-from 只用在 30 分 K;往上斜的通道不算;對不到 K 棒要提示;格式寬鬆但錯的要報錯
o = run(F30b, F60b, "--asof", "2026-11-18 11:30", "--channel-from", "2026-11-13 09:30")
p30, p60 = o.split("⑦")
check("通道只畫在 30 分 K", "通道上緣" in p30 and "通道" not in p60)
o = run(F30b, "--asof", "2026-11-18 11:30", "--channel-from", "2026-11-13T9:30")
check("--channel-from 少前導 0、用 T 也對得到", "通道上緣:線 40,056" in o)
o = run(F30b, "--asof", "2026-11-18 11:30", "--channel-from", "2026-11-13 09:15")
check("對不到 K 棒要提示", "⚠️ 通道:找不到 --channel-from 指定的 K 棒 2026-11-13 09:15" in o and "通道上緣:" not in o
      and "STAGE 3/6" in o)
o = run(F30b, "--asof", "2026-11-18 11:30", "--channel-from", "2026-11-06 09:00")
check("低點 1 比背離低點低 → 通道往上,不算", "通道不是往下,不算下降壓力線" in o and "通道上緣:" not in o
      and "STAGE 3/6" in o)
r = subprocess.run([sys.executable, "-I", SCRIPT, F30b, "--channel-from", "11-13 09:30"], capture_output=True, text=True)
check("--channel-from 格式錯 → 用法錯誤", r.returncode != 0 and "用法錯誤" in r.stderr and "Traceback" not in r.stderr)
for bad_v in ("0", "abc"):
    r = subprocess.run([sys.executable, "-I", SCRIPT, F30b, "--keep-days", bad_v], capture_output=True, text=True)
    check(f"--keep-days {bad_v} → 用法錯誤", r.returncode != 0 and "正整數" in r.stderr and "Traceback" not in r.stderr)
o = run(F30, F60)
check("背離保留時標題註明", "(回看 4 天:11/11 09:00 起;背離保留自 11/04 12:00)" in o)

# 6c. --zone-days 改區間範圍:只看 1 天 → 只剩 11/18 09:00 一個高點,區間退化成單一價位
o = run(F30b, "--asof", "2026-11-18 11:30", "--zone-days", "1")
check("zone-days 1 天", "區間 40,938.2(在區間下方" in o)

# 6d. 失效:11/19 09:30 跌破 11/18 背離低點 39,261 → ② 失效、退回 1/6、不畫圖;跌破前(11/19 09:00)仍是 3/6
F30c = os.path.join(HERE, "fixtures", "ix0001_30m_to_20261119.json")
o = run(F30c, "--asof", "2026-11-19 09:30")
check("跌破背離低點 → 失效", "② 底部背離: 失效 ❌ 11/19 09:30 跌破背離低點 39,260.99" in o and "STAGE 1/6" in o)
svg3 = os.path.join(TMP, "bs_test3.svg")
o = run(F30c, "--asof", "2026-11-19 09:30", "--svg", svg3)
check("失效後不畫圖", "SVG" not in o and not os.path.exists(svg3))
o = run(F30c, "--asof", "2026-11-19 09:00")
check("跌破前仍有效", "② 底部背離: 有 ✅" in o and "STAGE 3/6" in o)

# 6e. PR #41 review:回看範圍開始前就被跌破的舊背離是早就失效的,不報「失效」(看起來像剛失效),當作沒有背離
#     在 F30c 後面接兩天平盤 K 棒(11/20、11/21),--days 1 → 回看只剩 11/21,跌破發生在 11/19 → 舊背離不列
old = os.path.join(TMP, "bs_old.json")
try:
    d = json.load(open(F30c))
    lastc = sorted(d["data"], key=lambda b: b["date"])[-1]["close"]
    for day in ("2026-11-20", "2026-11-21"):
        for hm in ("09:00", "09:30", "10:00", "10:30", "11:00", "11:30", "12:00", "12:30", "13:00"):
            d["data"].append({"date": f"{day}T{hm}:00.000+08:00", "open": lastc, "high": lastc, "low": lastc,
                              "close": lastc, "volume": 1})
    json.dump(d, open(old, "w"))
    o = run(old, "--days", "1")
    check("舊背離早就跌破 → 不報失效", "失效" not in o and ("② 底部背離: 沒有 ❌" in o or "② 底部背離: ⏸" in o))
    o = run(old, "--days", "3")
    check("跌破在回看範圍內 → 照樣報失效", "② 底部背離: 失效 ❌ 11/19 09:30" in o)
finally:
    if os.path.exists(old): os.remove(old)

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

# 9. run.sh:用假 fugle.sh(FUGLE_SH)測抓資料失敗時不沿用上次的舊檔
import shutil
work = tempfile.mkdtemp(prefix="bs_run_", dir=TMP)
fake = os.path.join(work, "fake_fugle.sh")
open(fake, "w").write("""#!/bin/bash
# 假 fugle.sh:FAKE_MODE=ok | histfail | intrafail
case "$1" in
  historical/*timeframe=30*) SRC="%s" ;;
  historical/*timeframe=60*) SRC="%s" ;;
esac
# histfail:像斷線一樣不寫檔(curl -o 連不上時不會覆蓋舊檔),舊版 run.sh 會沿用上次的資料
if [ "$FAKE_MODE" = histfail ] && [[ "$1" == historical/* ]]; then echo '{"http":000}'; exit 0; fi
if [ "$FAKE_MODE" = hist60fail ] && [[ "$1" == historical/*timeframe=60* ]]; then echo '{"http":000}'; exit 0; fi
if [ "$FAKE_MODE" = intrafail ] && [[ "$1" == intraday/* ]]; then echo '{"http":000}'; exit 0; fi
# intratrunc:像 curl -m 逾時一樣,印 200、寫一半、結束碼 28
if [ "$FAKE_MODE" = intratrunc ] && [[ "$1" == intraday/* ]]; then printf '{"data":[{"date"' > "$2"; echo '{"http":200}'; exit 28; fi
# intraerr:不印狀態碼、寫錯誤內容
if [ "$FAKE_MODE" = intraerr ] && [[ "$1" == intraday/* ]]; then echo '{"statusCode":429,"message":"Rate limit exceeded"}' > "$2"; exit 0; fi
if [[ "$1" == historical/* ]]; then cat "$SRC" > "$2"; else echo '{"data":[]}' > "$2"; fi
[ "$FAKE_MODE" = quiet ] || echo '{"http": 200}'
""" % (F30, F60))
RUN = os.path.join(SCRIPTS, "run.sh")
def runsh(mode, session="0"):
    env = dict(os.environ, FUGLE_SH=fake, FAKE_MODE=mode, TW_IN_SESSION=session)
    return subprocess.run(["bash", RUN, "IX0001", work], capture_output=True, text=True, env=env)
try:
    r = runsh("ok")
    check("run.sh 正常", r.returncode == 0 and "STAGE 4/6" in r.stdout)
    r = runsh("quiet")
    check("run.sh fugle.sh 不印狀態碼但有寫檔 → 正常", r.returncode == 0 and "STAGE 4/6" in r.stdout)
    r = runsh("histfail")
    check("run.sh 歷史抓不到 → 報錯、不沿用舊檔", r.returncode != 0 and "資料錯誤" in r.stderr and "STAGE" not in r.stdout
          and not any(os.path.exists(os.path.join(work, f"bottom_IX0001_{tf}m.json")) for tf in (30, 60)))
    r = runsh("intrafail", "1")
    check("run.sh 交易時間盤中抓不到 → 警告、只用歷史", r.returncode == 0 and "警告" in r.stderr and "STAGE 4/6" in r.stdout)
    for mode in ("intratrunc", "intraerr"):
        r = runsh(mode, "1")
        check(f"run.sh 盤中 {mode} → 警告", r.returncode == 0 and "警告" in r.stderr and "STAGE 4/6" in r.stdout)
    r = runsh("ok", "1")
    check("run.sh 交易日盤中 K 是空的 → 警告", r.returncode == 0 and "盤中資料是空的" in r.stderr and "STAGE 4/6" in r.stdout)
    r = runsh("hist60fail")
    check("run.sh 只有 60 分歷史失敗 → 不留 30 分檔", r.returncode != 0
          and not any(n.startswith("bottom_") and n.endswith(".json") for n in os.listdir(work)))
    r = runsh("intrafail", "0")
    check("run.sh 非交易時間盤中抓不到 → 不警告", r.returncode == 0 and "警告" not in r.stderr and "STAGE 4/6" in r.stdout)
    env = dict(os.environ, FUGLE_SH=os.path.join(work, "no_such.sh"))
    r = subprocess.run(["bash", RUN, "IX0001", work], capture_output=True, text=True, env=env)
    check("run.sh 沒有 fugle.sh → 報錯", r.returncode != 0 and "找不到" in r.stderr)
finally:
    shutil.rmtree(work, ignore_errors=True)

sys.exit(1 if fails else 0)
