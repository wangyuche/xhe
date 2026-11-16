// mac-widget-kit 骨架檔案。不要修改;widget 只改 Widget.swift、Provider.swift、widget.json、README.md。
import AppKit
import SwiftUI

@MainActor
final class WidgetModel: ObservableObject {
    @Published var state: LoadState<Provider.Output> = .loading
    var onChange: (() -> Void)?

    func refresh() async {
        state = await Runner.fetch(forceError: false)
        onChange?()
    }
}

/// 統一外框:載入中、錯誤畫面由骨架負責,成功時才交給 WidgetView。
struct WidgetContainer: View {
    let state: LoadState<Provider.Output>
    let config: WidgetConfig

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView().controlSize(.small)
            case .loaded(let data, _):
                WidgetView(data: data)
            case .failed(let message):
                ErrorView(message: message)
            }
        }
        .padding(14)
        .frame(width: config.width, height: config.height)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.85))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ErrorView: View {
    let message: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            Text("無資料").font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct RootView: View {
    @ObservedObject var model: WidgetModel
    let config: WidgetConfig

    var body: some View {
        WidgetContainer(state: model.state, config: config)
            .contextMenu {
                Button("重新整理") { Task { await model.refresh() } }
                Button("結束") { NSApp.terminate(nil) }
            }
    }
}

/// 讓無邊框視窗可以用滑鼠拖曳。
final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    // SwiftUI 內容會吃掉 mouseDown,isMovableByWindowBackground 因此無效;
    // 左鍵按下直接交給視窗拖曳(右鍵選單不受影響)。
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

private struct SavedPosition: Codable {
    var x: Double
    var y: Double
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let config = AppEnv.config
    private let model = WidgetModel()
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var refreshTask: Task<Void, Never>?
    private let isSelfCheck = CommandLine.arguments.contains("--self-check")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if config.showsDesktop { makeWindow() }
        if config.showsMenuBar { makeStatusItem() }

        model.onChange = { [weak self] in self?.updateStatusTitle() }
        let model = self.model

        if isSelfCheck {
            Task {
                await model.refresh()
                self.printSelfCheck()
                exit(0)
            }
            return
        }

        let interval = max(1, config.refreshSeconds)
        refreshTask = Task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// --self-check:實際建好視窗 / 選單列項目後,印出狀態(不需要螢幕錄影權限)。
    private func printSelfCheck() {
        print("placement: \(config.placement)")
        if let w = window {
            print("window: level=\(w.level.rawValue) expected=\(Int(CGWindowLevelForKey(.desktopIconWindow)) + 1) visible=\(w.isVisible) size=\(Int(w.frame.width))x\(Int(w.frame.height))")
        }
        if let item = statusItem {
            print("statusItem: \(item.button?.title ?? "")")
        }
    }

    // MARK: 桌面浮窗

    private func makeWindow() {
        let size = NSSize(width: config.width, height: config.height)
        let w = NSWindow(
            contentRect: NSRect(origin: initialOrigin(size: size), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // 桌面圖示層 + 1:在 Finder 桌面圖示之上、一般視窗之下。
        w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = DraggableHostingView(rootView: RootView(model: model, config: config))
        w.delegate = self
        if isSelfCheck { w.alphaValue = 0 }   // 自我檢查:建立但不讓人看見
        w.orderFront(nil)
        window = w
    }

    private var stateURL: URL? { AppEnv.supportDir?.appendingPathComponent("state.json") }

    private func initialOrigin(size: NSSize) -> NSPoint {
        if let url = stateURL,
           let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode(SavedPosition.self, from: data) {
            let p = NSPoint(x: saved.x, y: saved.y)
            if NSScreen.screens.contains(where: { $0.visibleFrame.contains(p) }) { return p }
        }
        let f = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let m: CGFloat = 20
        switch config.position {
        case "top-left": return NSPoint(x: f.minX + m, y: f.maxY - size.height - m)
        case "bottom-left": return NSPoint(x: f.minX + m, y: f.minY + m)
        case "bottom-right": return NSPoint(x: f.maxX - size.width - m, y: f.minY + m)
        case "top-right": return NSPoint(x: f.maxX - size.width - m, y: f.maxY - size.height - m)
        default:
            let parts = config.position.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if parts.count == 2 {
                return NSPoint(x: f.minX + parts[0], y: f.maxY - parts[1] - size.height)
            }
            return NSPoint(x: f.maxX - size.width - m, y: f.maxY - size.height - m)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isSelfCheck, let w = window, let url = stateURL else { return }
        let saved = SavedPosition(x: w.frame.origin.x, y: w.frame.origin.y)
        if let data = try? JSONEncoder().encode(saved) { try? data.write(to: url) }
    }

    // MARK: 選單列

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = Runner.menuBarText(for: model.state)
        item.button?.target = self
        item.button?.action = #selector(statusClicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        popover.behavior = .transient
        popover.contentSize = NSSize(width: config.width, height: config.height)
        popover.contentViewController = NSHostingController(rootView: RootView(model: model, config: config))
    }

    private func updateStatusTitle() {
        statusItem?.button?.title = Runner.menuBarText(for: model.state)
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu = NSMenu()
            menu.addItem(withTitle: "重新整理", action: #selector(refreshNow), keyEquivalent: "").target = self
            menu.addItem(withTitle: "結束", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
            statusItem?.menu = menu
            sender.performClick(nil)
            statusItem?.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func refreshNow() {
        Task { await model.refresh() }
    }
}
