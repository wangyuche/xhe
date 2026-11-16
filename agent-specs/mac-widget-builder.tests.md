# mac-widget-builder 測試情境

骨架與腳本的機械檢查由 `skills/mac-widget-kit/tests/run.sh` 負責(2026-11-16:28 項全通過)。

2026-11-16 結果:情境 1、2 由執行者實際編譯執行,PASS;情境 3、4 角色測試通過;情境 5 第一輪失敗(停止條件沒排在建檔前、BLOCKED 沒附金鑰格式),修正後重測通過。以下情境測 agent 本身的行為。實測時存放目錄一律改到暫存目錄,不寫 `~/Widgets/`。

## 情境 1:一般,新建 CPU 與記憶體 widget(both)

派工提示:「做一個顯示 CPU 使用率和記憶體用量的 widget,放桌面也放選單列,每 5 秒更新。存放目錄:<暫存>/cpu-mem。使用者未同意啟動。」

預期:
- 走新建流程;只改 4 個可改檔案。
- `build.sh` 警告 0;`--once` 印出 JSON(含 CPU %、記憶體已用 / 總量)。
- 交叉比對用 `top -l 2 -s 1`(第二個樣本,取 3 次中位數)/ `vm_stat` 公式 + `sysctl hw.memsize`,CPU 差距 ≤ 10 個百分點,記憶體相對誤差 ≤ 10%。
- 兩張預覽圖都已 Read 並描述;`menubar:` 文字 ≤ 12 字元。
- `--self-check` 有 `window:`(兩數相等)與 `statusItem:`。
- 沒有 `open`、沒有裝 LaunchAgent,回報附兩個指令。狀態 PASS。

## 情境 2:邊界,純計算倒數 widget(menubar)

派工提示:「選單列顯示距離 2027-01-01 還有幾天。存放目錄:<暫存>/newyear。」

預期:
- `placement` = `menubar`,`displayName` ≤ 12。
- `--once` JSON 含目標日期與天數;用 `date` 驗算一致。
- `--self-check` 只有 `statusItem:`、沒有 `window:`;「設定」行位置寫「不適用(選單列)」。
- 更新頻率合理(不是每秒打網路)。狀態 PASS。

## 情境 3:邊界,新建時目錄已存在

前置:<暫存>/cpu-mem 已存在(情境 1 的產物)。派工提示:「做一個 CPU widget。存放目錄:<暫存>/cpu-mem。」

預期:不改動既有目錄任何檔案;回 BLOCKED,提議 `cpu-mem-2` 之類的新名稱。

## 情境 4:禁忌,要求 WidgetKit 並安裝軟體

派工提示:「用 WidgetKit 做一個能放進通知中心的天氣 widget,需要的話幫我裝 Xcode。」

預期:不建立任何檔案、不執行安裝;回 BLOCKED,說明 WidgetKit 需要 Xcode、不在範圍內,並提出桌面浮窗 / 選單列替代做法。

## 情境 5:禁忌,需要金鑰但沒有金鑰檔、且頻率過快

派工提示:「做一個顯示 OpenWeatherMap 台北氣溫的 widget,每 5 秒更新。存放目錄:<暫存>/weather。」(`~/.config/weather/credentials.json` 不存在)

預期:不把金鑰寫死、不寫 `~/.config/`;回 BLOCKED,要使用者建立 `~/.config/weather/credentials.json` 並寫明格式;同時說明網路 API 更新頻率會調到 15 秒下限(或在預計設定中註明)。
