// 可改檔案:widget 畫面。只處理「有資料」的情況,載入中與錯誤畫面由骨架負責。
import SwiftUI

struct WidgetView: View {
    let data: Provider.Output

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("現在時間").font(.caption).foregroundStyle(.secondary)
            Text(data.now)
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text("已開機 \(data.uptimeHours, specifier: "%.1f") 小時")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// 選單列文字(placement 為 menubar / both 時使用)。保持簡短,建議 12 字元內。
    static func menuBarText(_ data: Provider.Output) -> String {
        "⏱ \(data.now.prefix(5))"
    }
}
