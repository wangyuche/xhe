// 可改檔案:取資料。取不到時 throw WidgetError("原因"),骨架會顯示「無資料:原因」。
// 需要金鑰時用 try Credentials.require("key"),不要寫死在這裡。
import Foundation

struct Provider: WidgetProvider {
    struct Output: Codable, Sendable {
        let now: String
        let uptimeHours: Double
    }

    func fetch() async throws -> Output {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        let hours = (ProcessInfo.processInfo.systemUptime / 360).rounded() / 10
        return Output(now: f.string(from: Date()), uptimeHours: hours)
    }
}
