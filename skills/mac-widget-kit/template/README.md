# <displayName>

<一句話說明這個 widget 顯示什麼、資料來源、更新頻率。>

用 mac-widget-kit 建立(SwiftUI 桌面浮窗 / 選單列,免 Xcode)。

## 執行

```bash
bash <skill>/scripts/build.sh <本目錄>
open <本目錄>/build/<Name>.app
```

- 桌面浮窗:拖曳移動(位置存在 `state.json`),右鍵可「重新整理」「結束」。
- 選單列:點一下開啟完整畫面,右鍵可「重新整理」「結束」。

## 開機自動啟動

```bash
bash <skill>/scripts/install-agent.sh <本目錄>     # 安裝
bash <skill>/scripts/uninstall-agent.sh <本目錄>   # 移除
```

## 金鑰(需要時)

<不需要就刪掉這段。需要時說明 `~/.config/<name>/credentials.json` 的格式,例如 `{"apikey": "..."}`。>

## 刪除

先執行 `uninstall-agent.sh`(若有安裝),在 widget 上按右鍵「結束」,再刪除本目錄。
