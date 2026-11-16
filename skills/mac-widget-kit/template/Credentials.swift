// mac-widget-kit 骨架檔案。不要修改;widget 只改 Widget.swift、Provider.swift、widget.json、README.md。
import Foundation

/// 讀金鑰。widget 執行時一律讀 ~/.config/<name>/credentials.json(用 open 或 LaunchAgent 啟動的 app
/// 不會繼承 shell 的環境變數);只有 --once / --snapshot 測試時,環境變數 WIDGET_<KEY> 可以覆寫。
enum Credentials {
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/\(AppEnv.config.name)/credentials.json")
    }

    static func value(_ key: String) -> String? {
        let isCLI = CommandLine.arguments.contains { $0 == "--once" || $0.hasPrefix("--snapshot") }
        if isCLI, let v = ProcessInfo.processInfo.environment["WIDGET_" + key.uppercased()], !v.isEmpty {
            return v
        }
        guard let data = try? Data(contentsOf: fileURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj[key] as? String
    }

    static func require(_ key: String) throws -> String {
        guard let v = value(key) else {
            throw WidgetError("缺少金鑰 \(key):請在 ~/.config/\(AppEnv.config.name)/credentials.json 設定")
        }
        return v
    }
}
