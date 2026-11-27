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
    /// 桌面浮窗且也有選單列時才給:右鍵多一個「隱藏桌面浮窗」(之後從選單列右鍵再打開)。
    var onHideDesktop: (() -> Void)? = nil

    var body: some View {
        WidgetContainer(state: model.state, config: config)
            .contextMenu {
                Button("重新整理") { Task { await model.refresh() } }
                if let hide = onHideDesktop {
                    Button("隱藏桌面浮窗") { hide() }
                }
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

/// placement = both 時,桌面浮窗要不要顯示(選單列右鍵切換)。
/// 存在 prefs.json,不和 state.json 混用(骨架拖曳視窗後會整檔覆寫 state.json)。
private struct SavedPrefs: Codable {
    var showDesktop: Bool?
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

    /// placement = both:選單列一定有,桌面浮窗可從選單列右鍵開關(預設顯示,選擇會記住)。
    private var canToggleDesktop: Bool { config.showsDesktop && config.showsMenuBar }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // --self-check 一律建立視窗,才能檢查層級等狀態;不讀也不寫 prefs.json。
        if config.showsDesktop && (!canToggleDesktop || isSelfCheck || loadShowDesktop()) { makeWindow() }
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
            print("window: level=\(w.level.rawValue) expected=\(expectedLevel.rawValue) visible=\(w.isVisible) size=\(Int(w.frame.width))x\(Int(w.frame.height)) fullScreenAuxiliary=\(w.collectionBehavior.contains(.fullScreenAuxiliary))")
        }
        if let item = statusItem {
            print("statusItem: \(item.button?.title ?? "")")
        }
        if canToggleDesktop {
            print("desktopToggle: menubar-right-click")
        }
    }

    // MARK: 桌面浮窗

    private var expectedLevel: NSWindow.Level {
        config.floatsOnTop ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    }

    private func makeWindow() {
        let size = NSSize(width: config.width, height: config.height)
        let w = NSWindow(
            contentRect: NSRect(origin: initialOrigin(size: size), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        // 預設桌面圖示層 + 1:在 Finder 桌面圖示之上、一般視窗之下;level = floating 時在所有一般視窗之上。
        w.level = expectedLevel
        w.collectionBehavior = config.floatsOnTop
            ? [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            : [.canJoinAllSpaces, .stationary, .ignoresCycle]
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        let hide: (() -> Void)? = canToggleDesktop ? { [weak self] in self?.setDesktopVisible(false) } : nil
        w.contentView = DraggableHostingView(rootView: RootView(model: model, config: config, onHideDesktop: hide))
        w.delegate = self
        if isSelfCheck { w.alphaValue = 0 }   // 自我檢查:建立但不讓人看見
        w.orderFront(nil)
        window = w
    }

    private var stateURL: URL? { AppEnv.supportDir?.appendingPathComponent("state.json") }
    private var prefsURL: URL? { AppEnv.supportDir?.appendingPathComponent("prefs.json") }

    private func loadShowDesktop() -> Bool {
        guard let url = prefsURL, let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(SavedPrefs.self, from: data) else { return true }
        return prefs.showDesktop ?? true
    }

    private var isDesktopVisible: Bool { window?.isVisible ?? false }

    private func setDesktopVisible(_ show: Bool) {
        if show {
            if let w = window { w.orderFront(nil) } else { makeWindow() }
        } else {
            window?.orderOut(nil)
        }
        guard !isSelfCheck, let url = prefsURL,
              let data = try? JSONEncoder().encode(SavedPrefs(showDesktop: show)) else { return }
        try? data.write(to: url)
    }

    @objc private func toggleDesktop() { setDesktopVisible(!isDesktopVisible) }

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
            if canToggleDesktop {
                let item = menu.addItem(withTitle: "顯示桌面浮窗", action: #selector(toggleDesktop), keyEquivalent: "")
                item.target = self
                item.state = isDesktopVisible ? .on : .off
                menu.addItem(.separator())
            }
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
