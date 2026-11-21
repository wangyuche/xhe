// mac-widget-kit 骨架檔案。不要修改;widget 只改 Widget.swift、Provider.swift、widget.json、README.md。
//
// 參數:
//   --once                 取一次資料,印一行 JSON(失敗:stderr 寫原因、結束碼 1)
//   --snapshot <png>       取一次真實資料,輸出預覽 PNG,並印出該次資料
//   --snapshot-error <png> 模擬取資料失敗,輸出錯誤畫面預覽
//   --self-check           實際建立視窗 / 選單列項目,取一次資料後印出狀態並結束
//   (無參數)               以桌面浮窗 / 選單列常駐(同一個 widget 只允許一個常駐實例,已有一個在執行時直接結束,結束碼 0)
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

// 單一實例:手動 open 與 LaunchAgent(RunAtLoad)可能各啟動一次。用 flock 鎖住 Application Support 裡的
// instance.lock,程序結束(含當機)時系統自動放鎖。拿不到鎖 = 已有常駐實例 → 結束碼 0(LaunchAgent 不會重啟)。
// --self-check 不常駐,不搶鎖。
let instanceLock: Int32 = {
    guard !CommandLine.arguments.contains("--self-check"), let dir = AppEnv.supportDir else { return -1 }
    let fd = open(dir.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    if fd < 0 {
        Runner.stderr("警告:無法開啟 instance.lock(\(String(cString: strerror(errno)))),這次不保證只有一個實例")
        return -1
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        Runner.stderr("已有一個 \(AppEnv.config.name) 在執行,這個實例直接結束")
        exit(0)
    }
    return fd
}()

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
