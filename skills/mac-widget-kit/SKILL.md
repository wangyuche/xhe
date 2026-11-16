---
name: mac-widget-kit
description: Mac 桌面 widget 骨架與腳本(SwiftUI + AppKit,只需 Command Line Tools,免 Xcode)。提供桌面浮窗(桌面圖示層 + 1、無邊框、可拖曳、位置記憶)與選單列項目(NSStatusItem + NSPopover)、--once 取資料、--snapshot 預覽 PNG(免螢幕錄影權限)、--self-check、.app 打包與 ad-hoc 簽章、LaunchAgent 開機啟動。mac-widget-builder 建立或修改 widget 時使用;任何要在 Mac 桌面或選單列放常駐小資訊面板的情境也可用。
---

# mac-widget-kit

每個 widget 是一個獨立專案目錄,從 `template/` 複製出來。**只改 4 個檔案**:

| 檔案 | 內容 |
|---|---|
| `Widget.swift` | `struct WidgetView: View { let data: Provider.Output }` 和 `static func menuBarText(_:) -> String` |
| `Provider.swift` | `struct Provider: WidgetProvider { struct Output: Codable, Sendable; func fetch() async throws -> Output }` |
| `widget.json` | `name`、`displayName`、`width`、`height`、`placement`、`position`、`refreshSeconds`、`kit` 標記 |
| `README.md` | 這個 widget 的說明 |

其他檔案(`main.swift`、`Support.swift`、`WindowHost.swift`、`Snapshot.swift`、`Credentials.swift`)是骨架,不要改。載入中、錯誤畫面(「無資料:<原因>」)、右鍵「重新整理 / 結束」都由骨架負責。

## 腳本

`<kit>` = 這個 skill 的目錄。

```bash
bash <kit>/scripts/new-widget.sh <name> <dir>      # 建立;目錄已存在則失敗
bash <kit>/scripts/build.sh <dir>                  # 編譯 → <dir>/build/<Name>.app,印「警告:N」
<dir>/build/<Name>.app/Contents/MacOS/<Name> --once        # 取一次資料,印一行 JSON
bash <kit>/scripts/snapshot.sh <dir>               # → build/snapshot.png(+ stdout 資料、menubar: / menubar-length: 行;取資料失敗結束碼 3)
bash <kit>/scripts/snapshot.sh <dir> --error       # → build/snapshot-error.png(模擬錯誤)
<dir>/build/<Name>.app/Contents/MacOS/<Name> --self-check  # 建立視窗 / 選單列項目(不可見)後印狀態
bash <kit>/scripts/install-agent.sh <dir>          # 開機自動啟動(需使用者確認)
bash <kit>/scripts/uninstall-agent.sh <dir>        # 移除開機自動啟動
bash <kit>/tests/run.sh                            # 骨架自我測試
```

## widget.json

```json
{
  "kit": "mac-widget-kit",
  "name": "cpu-mem",
  "displayName": "CPU",
  "width": 320,
  "height": 160,
  "placement": "desktop",
  "position": "top-right",
  "refreshSeconds": 5
}
```

- `placement`:`desktop`(桌面浮窗)/ `menubar`(選單列文字,點擊彈出完整畫面)/ `both`。
- `position`:`top-right` / `top-left` / `bottom-right` / `bottom-left` / `"x,y"`(距螢幕可視範圍左上角)。拖曳後的位置存在 `state.json`。
- `refreshSeconds`:骨架最低 1 秒;網路 API 請自行設 ≥ 15。
- `displayName`:`placement` 含 `menubar` 時,錯誤狀態會顯示 `⚠︎ <displayName>`,長度請 ≤ 12。

## 寫 Provider 的規則

- 取不到資料就 `throw WidgetError("原因")`,不要回傳假數字。
- 金鑰用 `try Credentials.require("apikey")`,從 `~/.config/<name>/credentials.json` 讀;`--once` / `--snapshot` 測試時可用環境變數 `WIDGET_APIKEY` 覆寫。
- 系統資訊可用 `sysctl`、`host_processor_info`、`host_statistics64`(記憶體)、IOKit,或 `Process` 執行唯讀指令;CPU 的取法見下方「系統資訊的取法」。
- Swift 6 語言模式:`Output` 必須是 `Codable & Sendable`;`WidgetView` 在 MainActor 上。

## 寫 Widget 的規則

- 預覽用 `ImageRenderer`,**不支援** `ProgressView`、`Gauge`、`Toggle`、`Slider`、`TextField` 等由 AppKit 包裝的控制項(預覽上會變成黃底加禁止符號)。進度條、儀表請用 `Capsule`、`RoundedRectangle`、`Circle().trim` 自己畫。一定要 Read 預覽圖確認。
- 半透明材質(`.ultraThinMaterial` 等)在預覽上不會顯示透明效果;骨架背景用的是 0.85 透明度的系統視窗色加細邊框。

## 系統資訊的取法(實測)

- **CPU 使用率**:用 `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` 逐核加總 tick,間隔約 0.5 秒取兩次相減。不要用 `host_statistics(HOST_CPU_LOAD_INFO)`:短時間內連續呼叫會回傳相同的快取值,算不出差值。
- **CPU 交叉比對**:用 `top -l 2 -s 1 | grep 'CPU usage' | tail -1`(取第二個樣本;第一個樣本包含 top 自己啟動的負擔,常偏高 10–30 個百分點)。數值會跳動,取 3 次看中位數。
- **記憶體已用**(與活動監視器相同):`(anonymous − purgeable + wired + compressor) × page size`,四個值來自 `vm_stat` 的 `Anonymous pages`、`Pages purgeable`、`Pages wired down`、`Pages occupied by compressor`;總量用 `sysctl -n hw.memsize`。不要拿 `top` 的 `PhysMem used` 比對,它包含檔案快取。
- **更新頻率**:顯示到秒的時鐘 1 秒;只顯示到分或天的倒數 60 秒。

## 已知限制

- 預覽圖只能看 widget 畫面,選單列圖示本身和桌面上的實際位置無法截圖(不用螢幕錄影權限);用 `--self-check` 確認視窗層級與選單列文字。
- 拖曳、彈出視窗的點擊互動沒有自動測試,需要人在桌面上操作確認。
