#!/usr/bin/env python3
"""tw-stock-calc 的測試。執行:python3 -m unittest discover -s tests(在 skill 目錄下)。"""
import json
import os
import statistics
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.join(os.path.dirname(HERE), "scripts")
FIX = os.path.join(HERE, "fixtures")
sys.path.insert(0, SCRIPTS)

import indicators as ind  # noqa: E402
import valuation as val  # noqa: E402


def read(name):
    with open(os.path.join(FIX, name)) as f:
        return f.read()


def run(script, stdin, *args):
    p = subprocess.run([sys.executable, os.path.join(SCRIPTS, script), *args],
                       input=stdin, capture_output=True, text=True)
    return p.returncode, p.stdout, p.stderr


class TestParse(unittest.TestCase):
    def test_twse_roc_date_commas_and_concat(self):
        a = {"stat": "OK", "fields": ["日期", "成交股數", "開盤價", "最高價", "最低價", "收盤價"],
             "data": [["115/11/03", "1,000", "1,450.00", "1,460.00", "1,440.00", "1,455.00"],
                      ["115/11/04", "2,000", "--", "--", "--", "--"]]}
        b = {"stat": "OK", "fields": a["fields"],
             "data": [["115/11/03", "1,500", "1,450.00", "1,461.00", "1,440.00", "1,456.00"]]}
        rows = ind.parse_stream(json.dumps(a) + "\n" + json.dumps(b))
        self.assertEqual(len(rows), 1)  # 11/04 無成交被排除;11/03 重複保留最後一筆
        self.assertEqual(rows[0]["date"], "2026-11-03")
        self.assertEqual(rows[0]["close"], 1456.0)
        self.assertEqual(rows[0]["volume"], 1500.0)

    def test_finmind_and_tpex(self):
        fm = {"data": [{"date": "2026-11-03", "open": 1, "max": 3, "min": 0.5, "close": 2,
                        "Trading_Volume": 10}]}
        tp = {"stat": "ok", "tables": [{"fields": ["日 期", "成交張數", "成交仟元", "開盤", "最高", "最低", "收盤"],
                          "data": [["115/11/04", "5", "0", "2", "4", "1", "3"]]}]}
        rows = ind.parse_stream(json.dumps(fm) + json.dumps(tp))
        self.assertEqual([r["date"] for r in rows], ["2026-11-03", "2026-11-04"])
        self.assertEqual(rows[1]["high"], 4.0)


class TestIndicators(unittest.TestCase):
    def test_sma(self):
        self.assertEqual(ind.sma([1, 2, 3, 4, 5], 5)[-1], 3)
        self.assertIsNone(ind.sma([1, 2, 3, 4, 5], 5)[3])

    def test_ema_starts_at_first_value(self):
        e = ind.ema([10, 20], 3)  # α = 0.5
        self.assertEqual(e, [10, 15])

    def test_kd_first_value_and_flat(self):
        h = [10] * 8 + [12]
        l = [8] * 9
        c = [9] * 8 + [11]
        K, D = ind.kd(h, l, c)
        self.assertIsNone(K[7])
        rsv = (11 - 8) / (12 - 8) * 100  # 75
        self.assertAlmostEqual(K[8], 50 * 2 / 3 + rsv / 3)
        self.assertAlmostEqual(D[8], 50 * 2 / 3 + K[8] / 3)
        K2, D2 = ind.kd([5] * 12, [5] * 12, [5] * 12)  # 最高 = 最低 → RSV 50
        self.assertEqual((K2[-1], D2[-1]), (50, 50))

    def test_rsi_wilder(self):
        self.assertEqual(ind.rsi(list(range(1, 17)))[-1], 100.0)
        c = [10, 11] * 8  # 15 次變動:漲 8、跌 7
        r = ind.rsi(c)
        self.assertIsNone(r[13])
        ag, al = 7 / 14, 7 / 14  # 前 14 次變動:漲 7 次、跌 7 次
        self.assertAlmostEqual(r[14], 100 - 100 / (1 + ag / al))
        ag, al = (ag * 13 + 1) / 14, (al * 13 + 0) / 14  # 第 15 次變動 +1
        self.assertAlmostEqual(r[15], 100 - 100 / (1 + ag / al))

    def test_macd_flat_is_zero(self):
        dif, sig, hist = ind.macd([100] * 40)
        self.assertEqual((dif[-1], sig[-1], hist[-1]), (0, 0, 0))

    def test_fixture_end_to_end_matches_reference(self):
        text = read("twse_stock_day.json")
        code, out, err = run("indicators.py", text)
        self.assertEqual(code, 0, err)
        res = json.loads(out)
        self.assertEqual(res["count"], 130)
        self.assertFalse(res["adjusted"])
        self.assertIsNone(res["warning"])
        # 用另一種寫法獨立重算,對照四捨五入到 2 位的結果
        rows = ind.parse_stream(text)
        c = [r["close"] for r in rows]
        h = [r["high"] for r in rows]
        l = [r["low"] for r in rows]
        k = d = 50.0
        for i in range(8, len(c)):
            hh, ll = max(h[i - 8:i + 1]), min(l[i - 8:i + 1])
            rsv = 50.0 if hh == ll else (c[i] - ll) / (hh - ll) * 100
            k = (2 * k + rsv) / 3
            d = (2 * d + k) / 3
        e12 = e26 = c[0]
        sigv = None
        for x in c:
            e12 += (x - e12) * 2 / 13
            e26 += (x - e26) * 2 / 27
            dif = e12 - e26
            sigv = dif if sigv is None else sigv + (dif - sigv) * 2 / 10
        lt = res["latest"]
        self.assertEqual(lt["ma20"], round(sum(c[-20:]) / 20, 2))
        self.assertEqual(lt["k"], round(k, 2))
        self.assertEqual(lt["d"], round(d, 2))
        self.assertAlmostEqual(lt["dif"], round(dif, 2), places=2)
        self.assertAlmostEqual(lt["macd"], round(sigv, 2), places=2)
        self.assertIsNotNone(res["levels"]["volume_dense_zone_60"])

    def test_short_data_warns(self):
        text = read("twse_stock_day.json").splitlines()[0]
        res = json.loads(run("indicators.py", text)[1])
        self.assertIn("少於", res["warning"])

    def test_empty_input_errors(self):
        code, out, _ = run("indicators.py", '{"stat":"很抱歉,沒有符合條件的資料!"}')
        self.assertEqual(code, 1)
        self.assertIn("error", json.loads(out))


class TestValuation(unittest.TestCase):
    def test_percentile_matches_statistics_inclusive(self):
        vals = sorted([3.0, 1.0, 4.0, 1.5, 5.0, 9.0, 2.0, 6.0])
        q = statistics.quantiles(vals, n=4, method="inclusive")
        self.assertAlmostEqual(val.pct(vals, 0.25), q[0])
        self.assertAlmostEqual(val.pct(vals, 0.75), q[2])

    def test_fixture(self):
        text = read("finmind_per.json")
        code, out, err = run("valuation.py", text, "--eps4q", "40", "--bvps", "200",
                             "--dividend", "20", "--price", "800")
        self.assertEqual(code, 0, err)
        res = json.loads(out)
        m = {x["method"]: x for x in res["methods"]}
        self.assertEqual(m["本益比區間"]["valid_count"], 294)  # 排除 6 筆 0
        self.assertEqual(m["殖利率法"]["valid_count"], 295)  # 排除 5 筆空值
        data = json.loads(text)["data"]
        pers = sorted(float(r["PER"]) for r in data if float(r["PER"]) > 0)
        q = statistics.quantiles(pers, n=4, method="inclusive")
        self.assertEqual(m["本益比區間"]["fair_low"], round(40 * q[0], 2))
        self.assertEqual(m["本益比區間"]["fair_high"], round(40 * q[2], 2))
        dy = m["殖利率法"]
        self.assertLess(dy["fair_low"], dy["fair_high"])  # P75 殖利率 → 低價
        self.assertIn(res["verdict"], ("偏便宜", "合理", "偏貴"))

    def test_not_applicable_cases(self):
        text = read("finmind_per.json")
        res = json.loads(run("valuation.py", text, "--eps4q", "-3", "--bvps", "200")[1])
        m = {x["method"]: x for x in res["methods"]}
        self.assertFalse(m["本益比區間"]["applicable"])
        self.assertIn("≤ 0", m["本益比區間"]["reason"])
        self.assertFalse(m["殖利率法"]["applicable"])  # 未給股利
        short = json.dumps({"data": json.loads(text)["data"][:100]})
        res = json.loads(run("valuation.py", short, "--bvps", "200")[1])
        self.assertIn("< 250", res["methods"][1]["reason"])
        res = json.loads(run("valuation.py", '{"data":[]}', "--eps4q", "40")[1])
        self.assertTrue(all(not x["applicable"] for x in res["methods"]))

    def _ranges(self, text):
        res = json.loads(run("valuation.py", text, "--eps4q", "40", "--bvps", "200",
                             "--dividend", "20")[1])
        return {x["method"]: x for x in res["methods"]}

    def test_majority_verdict(self):
        text = read("finmind_per.json")
        m = self._ranges(text)
        highs = sorted(x["fair_high"] for x in m.values())
        lows = sorted(x["fair_low"] for x in m.values())
        # 高於兩種方法上限、但仍在最寬區間內 → 舊規則會判「合理」,多數決要判「偏貴」
        price = (highs[1] + highs[2]) / 2
        if price < lows[2]:
            self.skipTest("fixture 區間配置不適合此情境")
        res = json.loads(run("valuation.py", text, "--eps4q", "40", "--bvps", "200",
                             "--dividend", "20", "--price", str(price))[1])
        self.assertLessEqual(price, res["fair_range"]["high"])
        self.assertEqual(res["verdict"], "偏貴")
        res = json.loads(run("valuation.py", text, "--eps4q", "40", "--bvps", "200",
                             "--dividend", "20", "--price", str(lows[0] - 1))[1])
        self.assertEqual(res["verdict"], "偏便宜")

    def test_bvps_derived_from_latest_pbr(self):
        text = read("finmind_per.json")
        data = json.loads(text)["data"]
        last = max(data, key=lambda r: r["date"])
        res = json.loads(run("valuation.py", text, "--price", "800")[1])
        pb = res["methods"][1]
        self.assertTrue(pb["applicable"])
        self.assertEqual(pb["base"], round(800 / float(last["PBR"]), 2))
        self.assertIn("推得", pb["note"])

    def test_bad_input_errors(self):
        code, out, _ = run("valuation.py", "<html>blocked</html>", "--eps4q", "40")
        self.assertEqual(code, 1)
        self.assertIn("error", json.loads(out))

    def test_finmind_quota_errors(self):
        # FinMind 額度用完回 402、沒有 data:要結束碼 1 並說明是資料缺口,不能變成三種方法「不適用」
        quota = '{"msg":"Requests reach the upper limit. https://finmindtrade.com/","status":402}'
        code, out, _ = run("valuation.py", quota, "--eps4q", "40", "--price", "800")
        res = json.loads(out)
        self.assertEqual(code, 1)
        self.assertEqual(res["status"], 402)
        self.assertIn("額度用完", res["error"])
        self.assertNotIn("methods", res)
        code, out, _ = run("valuation.py", '{"msg":"token is invalid","status":401}', "--eps4q", "40")
        self.assertEqual(code, 1)
        self.assertIn("status 401", json.loads(out)["error"])
        code, out, _ = run("valuation.py", '{"msg":"rate limited"}', "--eps4q", "40")
        self.assertEqual(code, 1)
        # 正常但沒資料(status 200、data 空)仍是不適用,結束碼 0
        code, out, _ = run("valuation.py", '{"msg":"success","status":200,"data":[]}', "--eps4q", "40")
        self.assertEqual(code, 0)
        self.assertFalse(json.loads(out)["methods"][0]["applicable"])


class TestForecast(unittest.TestCase):
    def test_band(self):
        code, out, err = run("forecast.py", "", "--supports", "1450", "1430",
                             "--resistances", "1500", "1515", "--avg-range", "30")
        self.assertEqual(code, 0, err)
        res = json.loads(out)
        self.assertEqual((res["low"], res["high"]), (1415.0, 1530.0))
        self.assertLessEqual(res["low"], res["lowest_support"])
        self.assertLess(res["lowest_support"], res["highest_resistance"])
        self.assertLessEqual(res["highest_resistance"], res["high"])

    def test_overlap_errors(self):
        code, out, _ = run("forecast.py", "", "--supports", "1500",
                           "--resistances", "1490", "--avg-range", "30")
        self.assertEqual(code, 1)
        self.assertIn("error", json.loads(out))

    def test_avg_range_from_indicators(self):
        out = json.loads(run("indicators.py", read("twse_stock_day.json"))[1])
        rows = ind.parse_stream(read("twse_stock_day.json"))[-10:]
        exp = round(sum(r["high"] - r["low"] for r in rows) / 10, 2)
        self.assertEqual(out["latest"]["avg_range_10d"], exp)


if __name__ == "__main__":
    unittest.main()
