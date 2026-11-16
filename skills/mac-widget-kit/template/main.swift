// mac-widget-kit 骨架檔案。不要修改;widget 只改 Widget.swift、Provider.swift、widget.json、README.md。
//
// 參數:
//   --once                 取一次資料,印一行 JSON(失敗:stderr 寫原因、結束碼 1)
//   --snapshot <png>       取一次真實資料,輸出預覽 PNG,並印出該次資料
//   --snapshot-error <png> 模擬取資料失敗,輸出錯誤畫面預覽
//   --self-check           實際建立視窗 / 選單列項目,取一次資料後印出狀態並結束
//   (無參數)               以桌面浮窗 / 選單列常駐
import AppKit

if CommandLine.arguments.contains("--once") {
    exit(await Runner.once())
}

for (flag, forceError) in [("--snapshot", false), ("--snapshot-error", true)] {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: flag), i + 1 < args.count {
        exit(await Snapshot.run(path: args[i + 1], forceError: forceError))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
