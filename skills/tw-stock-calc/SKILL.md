---
name: tw-stock-calc
description: 台股技術指標與合理價的固定計算腳本(MA、KD(9,3,3)、RSI(14) Wilder、MACD(12,26,9)、量能倍數、支撐壓力候選、本益比/股價淨值比/殖利率百分位估值)。用 curl 抓證交所、櫃買中心或 FinMind 的 JSON,管線交給腳本,不寫任何檔案。tw-stock-analyst 計算技術面與價值估算時使用;任何需要可重現台股指標的情境也可用。
---

# tw-stock-calc

把 tw-stock-analyst 規格裡寫死的演算法做成腳本,讓每次計算結果一致、可重現。**不要自己重寫這些演算法,一律呼叫腳本。**

腳本位置(全域安裝後):`~/.claude/skills/tw-stock-calc/scripts/`。只用 Python 標準函式庫,讀 stdin、輸出 JSON 到 stdout,不寫檔。

## 技術指標:`indicators.py`

上市股(證交所 STOCK_DAY 一次回傳一個月,**抓 7 個月**才能確保至少 120 筆;6 個月實測只有約 113 筆):

```bash
{ for m in 20260501 20260601 20260701 20260801 20260901 20261001 20261101; do
    curl -s "https://www.twse.com.tw/rwd/zh/afterTrading/STOCK_DAY?date=$m&stockNo=2330&response=json"; echo
  done; } | python3 ~/.claude/skills/tw-stock-calc/scripts/indicators.py
```

上櫃股:櫃買中心 tradingStock(一次一個月,同樣抓 7 個月):

```bash
{ for m in 2026/05/01 2026/06/01 2026/07/01 2026/08/01 2026/09/01 2026/10/01 2026/11/01; do
    curl -s "https://www.tpex.org.tw/www/zh-tw/afterTrading/tradingStock?code=6488&date=$m&response=json"; echo
  done; } | python3 ~/.claude/skills/tw-stock-calc/scripts/indicators.py
```

備援(上市、上櫃都可用):FinMind(一次抓完整區間,未還原):

```bash
curl -s "https://api.finmindtrade.com/api/v4/data?dataset=TaiwanStockPrice&data_id=6488&start_date=2026-04-01" \
  | python3 ~/.claude/skills/tw-stock-calc/scripts/indicators.py
```

需要 token 時用 `-H "Authorization: Bearer $FINMIND_TOKEN"`,不要把 token 寫進網址或印出來。

支援的輸入:證交所 STOCK_DAY、櫃買中心 tradingStock(`tables`)、FinMind TaiwanStockPrice,以及 `[{date,open,high,low,close,volume}]` 陣列;多個 JSON 可直接串接。日期重複時保留最後一筆,收盤為空(無成交)的日子排除。

輸出重點欄位:
- `start` / `end` / `count` / `adjusted`(固定 false):報告「技術面」段落的資料說明直接用這些。
- `warning`:筆數少於 120 時出現,要多抓一個月再算,或在報告註明。
- `latest`:收盤、MA5/20/60、K、D、RSI14、DIF、MACD、柱狀體、`volume_ratio_20d`、`avg_range_10d`(近 10 日平均振幅,給 `forecast.py` 用)。
- `previous`:前一日的 K、D、DIF、MACD,用來判斷黃金交叉 / 死亡交叉。
- `levels`:近 60 筆前波高點 / 低點、MA20、MA60、成交密集區,作為支撐壓力候選,報告要寫明每個價位取自哪一項。
- `error`:沒有可用資料時出現,結束碼為 1。這時換下一個來源(證交所 / 櫃買中心 → FinMind)重抓;所有來源都失敗才標「無資料」。

## 價值估算:`valuation.py`

```bash
curl -s "https://api.finmindtrade.com/api/v4/data?dataset=TaiwanStockPER&data_id=2330&start_date=2021-11-15" \
  | python3 ~/.claude/skills/tw-stock-calc/scripts/valuation.py \
      --eps4q <近4季EPS合計> --bvps <最新每股淨值> --dividend <近一年現金股利> --price <目前股價>
```

沒有的數字不要給(例如未配息就不給 `--dividend`),該方法會標為不適用並附原因。沒給 `--bvps` 時,腳本用「`--price` ÷ 最新一筆 PBR」推每股淨值(`--price` 要用資料截至日的收盤價)。輸出每種方法的 `valid_count`、`p25`、`p75`、`fair_low`、`fair_high`、`position`(高於上限 / 區間內 / 低於下限),或 `applicable: false` 加 `reason`;另有 `fair_range`(只供顯示)、`verdict`(偏便宜 / 合理 / 偏貴)與 `verdict_rule`。回應無法解析(例如被擋時回 HTML)或 FinMind 回錯誤狀態(`status` 不是 200,例如 **402 額度用完**、401 token 無效)會輸出 `error`(含 `status`、`api_message`),結束碼 1:這是**資料缺口**,不是「不適用」,報告要寫成資料缺口並附原因(402 時建議設定 `FINMIND_TOKEN` 或稍後重試)。

## 短期預估區間:`forecast.py`

```bash
python3 ~/.claude/skills/tw-stock-calc/scripts/forecast.py \
    --supports 1450 1430 --resistances 1500 1515 --avg-range <latest.avg_range_10d>
```

支撐、壓力由你從 `indicators.py` 的 `levels` 挑選,`--avg-range` 直接用 `latest.avg_range_10d`。輸出 `low`、`high`;支撐與壓力重疊時輸出 `error`,要重新挑選。

## 固定演算法(給人看的說明,腳本已實作)

- **MA n**:最近 n 筆收盤價簡單平均。
- **KD(9,3,3)**:從第 9 筆開始;RSV = (今收 − 9 日最低價) ÷ (9 日最高價 − 9 日最低價) × 100,最高等於最低時 RSV = 50;K = 前K×2/3 + RSV×1/3,D = 前D×2/3 + K×1/3;第 9 筆的前 K、前 D = 50。
- **RSI(14)**:Wilder;第一個平均漲跌幅 = 前 14 次變動的簡單平均,之後 = (前平均×13 + 當日)÷14。平均跌幅為 0 時 RSI = 100(平均漲幅也為 0 時 = 50)。
- **MACD(12,26,9)**:EMA α = 2/(n+1),第一個 EMA = 第一筆收盤;DIF = EMA12 − EMA26;MACD = DIF 的 9 日 EMA(從第一個 DIF 起算);柱 = DIF − MACD。
- **量能倍數**:最後一筆成交量 ÷ 含最後一筆在內的近 20 筆平均量。
- **前波高低點**:近 60 筆中,左右各 3 筆範圍內的最高價 / 最低價。
- **成交密集區**:近 60 筆收盤價在高低範圍內分 20 箱,成交量加總最大的一箱。
- **估值百分位**:排除 ≤0 與空值後線性內插(位置 = (n−1)×p,同 numpy 預設);有效筆數 < 250 時不適用。殖利率法:股利 ÷ P75 殖利率為下限、÷ P25 為上限。合理價區間 = 各適用方法下限取最小、上限取最大(只供顯示)。
- **偏貴 / 偏便宜判定(多數決)**:股價高於過半適用方法的上限 → 偏貴;低於過半適用方法的下限 → 偏便宜;其餘 → 合理。
- **近 10 日平均振幅**:近 10 筆(最高價 − 最低價)的簡單平均。
- **短期預估區間**:下限 = 最低支撐 − 0.5 × 近 10 日平均振幅;上限 = 最高壓力 + 0.5 × 近 10 日平均振幅。

## 測試

在 skill 目錄執行 `python3 -m unittest discover -s tests`。`tests/fixtures/` 有合成的證交所日線與 FinMind 本益比資料;測試用另一種寫法獨立重算並對照結果。
