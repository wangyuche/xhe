// mac-widget-kit 骨架檔案。不要修改;widget 只改 Widget.swift、Provider.swift、widget.json、README.md。
import AppKit
import SwiftUI

/// 不開視窗、不需螢幕錄影權限,把 widget 畫面輸出成 PNG(2 倍解析度)。
/// 結束碼:0 成功;2 無法寫出影像;3 一般預覽但取資料失敗(圖上是錯誤畫面)。
@MainActor
enum Snapshot {
    static func run(path: String, forceError: Bool) async -> Int32 {
        let state = await Runner.fetch(forceError: forceError)
        switch state {
        case .loaded(let o, _): print(Runner.json(o))
        case .failed(let m): Runner.stderr("無資料:\(m)")
        case .loading: break
        }
        if AppEnv.config.showsMenuBar {
            let text = Runner.menuBarText(for: state)
            print("menubar: \(text)")
            print("menubar-length: \(text.count)")
        }

        let renderer = ImageRenderer(content: WidgetContainer(state: state, config: AppEnv.config))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            Runner.stderr("snapshot 失敗:無法產生影像")
            return 2
        }
        do {
            try png.write(to: URL(fileURLWithPath: path))
        } catch {
            Runner.stderr("snapshot 失敗:\(error.localizedDescription)")
            return 2
        }
        // 一般預覽取資料失敗:圖已寫出(錯誤畫面),但結束碼 3,避免被當成成功預覽。
        if !forceError, case .failed = state { return 3 }
        return 0
    }
}
