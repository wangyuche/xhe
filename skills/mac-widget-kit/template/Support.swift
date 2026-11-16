// mac-widget-kit 骨架檔案。不要修改;widget 只改 Widget.swift、Provider.swift、widget.json、README.md。
import Foundation

/// Provider.swift 要符合的介面。
protocol WidgetProvider: Sendable {
    associatedtype Output: Codable & Sendable
    init()
    func fetch() async throws -> Output
}

/// Provider 取不到資料時拋這個,訊息會顯示在「無資料:<原因>」。
struct WidgetError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum LoadState<Output: Sendable>: Sendable {
    case loading
    case loaded(Output, Date)
    case failed(String)
}

struct WidgetConfig: Codable, Sendable {
    var kit: String
    var name: String
    var displayName: String
    var width: Double
    var height: Double
    var placement: String      // desktop | menubar | both
    var position: String       // top-right | top-left | bottom-right | bottom-left | "x,y"(距可視範圍左上角)
    var refreshSeconds: Double

    static let fallback = WidgetConfig(
        kit: "mac-widget-kit", name: "widget", displayName: "Widget",
        width: 320, height: 160, placement: "desktop", position: "top-right", refreshSeconds: 5)

    var showsDesktop: Bool { placement == "desktop" || placement == "both" }
    var showsMenuBar: Bool { placement == "menubar" || placement == "both" }
    var title: String { displayName.isEmpty ? name : displayName }
}

enum AppEnv {
    static let projectDir: URL? = locateProjectDir()
    static let loaded: (config: WidgetConfig, error: String?) = loadConfig()
    static var config: WidgetConfig { loaded.config }

    private static func hasConfig(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("widget.json").path)
    }

    /// 以 Info.plist 的 WidgetProjectDir 為準;找不到時從執行檔位置
    /// (<dir>/build/<Name>.app/Contents/MacOS/<Name>)往上推回。
    private static func locateProjectDir() -> URL? {
        if let p = Bundle.main.object(forInfoDictionaryKey: "WidgetProjectDir") as? String {
            let u = URL(fileURLWithPath: p)
            if hasConfig(u) { return u }
        }
        if var u = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            for _ in 0..<5 { u.deleteLastPathComponent() }
            if hasConfig(u) { return u }
        }
        return nil
    }

    private static func loadConfig() -> (config: WidgetConfig, error: String?) {
        guard let dir = projectDir else { return (.fallback, "找不到 widget.json") }
        do {
            let data = try Data(contentsOf: dir.appendingPathComponent("widget.json"))
            return (try JSONDecoder().decode(WidgetConfig.self, from: data), nil)
        } catch {
            return (.fallback, "widget.json 格式錯誤:\(error.localizedDescription)")
        }
    }
}

enum Runner {
    static func fetch(forceError: Bool) async -> LoadState<Provider.Output> {
        if let e = AppEnv.loaded.error { return .failed(e) }
        if forceError || ProcessInfo.processInfo.environment["WIDGET_FORCE_ERROR"] == "1" {
            return .failed("模擬錯誤")
        }
        do {
            return .loaded(try await Provider().fetch(), Date())
        } catch {
            return .failed(message(for: error))
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    static func json(_ output: Provider.Output) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let d = try? enc.encode(output), let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    @MainActor
    static func menuBarText(for state: LoadState<Provider.Output>) -> String {
        switch state {
        case .loaded(let data, _): return WidgetView.menuBarText(data)
        case .loading: return "…"
        case .failed: return "⚠︎ \(AppEnv.config.title)"
        }
    }

    static func stderr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// --once:印一行 JSON;失敗時 stderr 寫原因、結束碼 1。
    static func once() async -> Int32 {
        switch await fetch(forceError: false) {
        case .loaded(let o, _):
            print(json(o))
            return 0
        case .failed(let m):
            stderr("無資料:\(m)")
            return 1
        case .loading:
            return 1
        }
    }
}
