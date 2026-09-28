// App.swift — Wattson 原生菜单栏 App（AppKit 托管 + SwiftUI 视图）。
// 状态栏图标：左键弹状态栏小窗（原 popup 语义），右键弹菜单
// （打开完整看板 / 刷新数据 / 设置… / 立即同步远端 / 登录时启动 / 查看日志… / 退出），
// 与原 Electron 托盘行为一一对应。看板窗口由本类托管，设置入口整合在主面板侧栏。
import WattsonCore
import SwiftUI
import AppKit
import Combine
import ServiceManagement

// 入口：直接以 AppKit 托管（不再挂 SwiftUI Settings scene）。
// 原因：macOS 26+ 会把「只有 Settings scene」的应用在启动时自动弹出标准
// 设置窗——里面是 EmptyView，就是 2.3.0 发布版「启动弹空白设置窗」的根因。
// 全部窗口（状态栏小窗/看板/设置）由本类手动托管，无需任何 SwiftUI scene。
@main
struct WattsonAppMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var popup: NSPopover?
    private var dashboardWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellable: AnyCancellable?
    private var lastPopupHideAt: TimeInterval = 0
    private var mirrorProcessRunning = false
    // 置顶迷你视图（菜单项开关；nil = 关闭）
    private var floatPanel: NSPanel?
    private var notchPanel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        appState.openSettingsHandler = { [weak self] page in self?.openSettings(page) }
        appState.loadDevices()  // 启动即读远端设备列表（popup 初始化入口 / 镜像入口依据）
        setupStatusItem()
        cancellable = appState.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.statusItem?.button?.title = self?.appState.menuTitle ?? "⚡"
            }
        }
    }

    // MARK: 状态栏图标（左键小窗 / 右键菜单）

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = appState.menuTitle
        item.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked(_:))
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { togglePopup(); return }
        // ctrl+左键 = 右键等效（macOS 无独立 controlLeftMouseUp 事件类型）
        let isControlClick = event.modifierFlags.contains(.control)
        if event.type == .rightMouseUp || (event.type == .leftMouseUp && isControlClick) {
            showContextMenu()
        } else {
            togglePopup()
        }
    }

    private func togglePopup() {
        // 刚因点击外部/再点图标而关闭时，本次点击视为「关闭」而非立即重开
        if Date.timeIntervalSinceReferenceDate - lastPopupHideAt < 0.3 { return }
        if let pop = popup, pop.isShown {
            pop.performClose(nil)
            return
        }
        guard let button = statusItem?.button else { return }
        // NSPopover 由系统锚定在状态项图标正下方（Control Center 同款机制）：
        // 位置随图标所在屏幕自动正确，任何显示器排列下都不会错位
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: PopupView(state: appState, openDashboard: { [weak self] in self?.openDashboard() }))
        pop.delegate = self
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popup = pop
    }

    private func hidePopup() {
        popup?.performClose(nil)
    }

    // MARK: 右键菜单（原 trayMenu 语义）

    private func showContextMenu() {
        hidePopup() // 右键菜单弹出前先收起小窗（若有）
        let menu = NSMenu()
        menu.autoenablesItems = false

        let open = NSMenuItem(title: "打开完整看板", action: #selector(menuOpenDashboard), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let refresh = NSMenuItem(title: appState.refreshing ? "采集中…" : "刷新数据",
                                 action: appState.refreshing ? nil : #selector(menuRefresh), keyEquivalent: "")
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: "设置…（设备与初始化）", action: #selector(menuOpenSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let sync = NSMenuItem(title: mirrorProcessRunning ? "同步远端中…" : "立即同步远端",
                              action: mirrorProcessRunning ? nil : #selector(menuSyncRemote), keyEquivalent: "")
        sync.target = self
        menu.addItem(sync)
        menu.addItem(.separator())

        let login = NSMenuItem(title: "登录时启动", action: #selector(menuToggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        let log = NSMenuItem(title: "查看日志…", action: #selector(menuOpenLogFile), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let doctor = NSMenuItem(title: "诊断…", action: #selector(menuRunDoctor), keyEquivalent: "")
        doctor.target = self
        menu.addItem(doctor)

        let floatItem = NSMenuItem(title: "悬浮组件", action: #selector(menuToggleFloat), keyEquivalent: "")
        floatItem.target = self
        floatItem.state = floatPanel != nil ? .on : .off
        menu.addItem(floatItem)

        let notchItem = NSMenuItem(title: "灵动岛", action: #selector(menuToggleNotch), keyEquivalent: "")
        notchItem.target = self
        notchItem.state = notchPanel != nil ? .on : .off
        menu.addItem(notchItem)

        let quit = NSMenuItem(title: "退出 Wattson", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil) // 以图标为锚弹出菜单
        statusItem?.menu = nil                // 菜单关闭后恢复左键行为
    }

    @objc private func menuOpenDashboard() { openDashboard() }
    @objc private func menuRefresh() { Task { await appState.refreshNow() } }
    @objc private func menuOpenSettings() { openSettings(.devices) }
    @objc private func menuSyncRemote() { appState.runMirrorNow() }
    @objc private func menuToggleLoginItem() { appState.toggleLoginItem() }
    @objc private func menuOpenLogFile() { appState.openLogFile() }

    @objc private func menuRunDoctor() {
        let report = doctorChecks()
        let alert = NSAlert()
        alert.messageText = report.allOk ? "诊断：全部检查通过" : "诊断：存在未通过项"
        alert.informativeText = renderDoctorReport(report)
        alert.alertStyle = report.allOk ? .informational : .warning
        alert.runModal()
    }

    // MARK: 悬浮组件 / 灵动岛（NSPanel 置顶迷你视图，同一开关方法复用）

    @objc private func menuToggleFloat() {
        toggleOverlayPanel(&floatPanel, size: NSSize(width: 250, height: 190),
                           content: AnyView(FloatWidgetView(state: appState)), notch: false)
    }

    @objc private func menuToggleNotch() {
        toggleOverlayPanel(&notchPanel, size: NSSize(width: 300, height: 42),
                           content: AnyView(NotchPillView(state: appState)), notch: true)
    }

    /// 无边框非激活面板：点击不抢焦点、跨全部 Space、跟随系统外观配色。
    /// 灵动岛变体钉在主屏（刘海屏）顶部居中，普通变体居中显示、可拖动。
    private func toggleOverlayPanel(_ box: inout NSPanel?, size: NSSize,
                                    content: AnyView, notch: Bool) {
        if let panel = box {
            panel.orderOut(nil)
            box = nil
            return
        }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = notch ? .statusBar : .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: content)
        if notch, let screen = NSScreen.screens.first ?? NSScreen.main {
            let f = screen.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 2))
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        box = panel
    }

    // MARK: 看板窗口

    func openDashboard() {
        hidePopup()
        if let win = dashboardWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable],
                           backing: .buffered, defer: false)
        win.title = "Wattson · AI 用量看板"
        win.backgroundColor = Theme.nsBg
        win.minSize = NSSize(width: 980, height: 640)
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: DashboardView(state: appState))
        win.center()
        win.makeKeyAndOrderFront(nil)
        dashboardWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: 设置窗口（独立窗口：主面板保持纯数据展示）

    func openSettings(_ page: SettingsPage? = nil) {
        hidePopup()
        if let win = settingsWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "设置"
        win.backgroundColor = Theme.nsBg
        win.isReleasedWhenClosed = false
        win.contentView = NSHostingView(rootView: SettingsView(state: appState, initialPage: page ?? .general))
        win.center()
        win.makeKeyAndOrderFront(nil)
        settingsWindow = win
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: NSPopoverDelegate / NSWindowDelegate

    func popoverDidClose(_ notification: Notification) {
        lastPopupHideAt = Date.timeIntervalSinceReferenceDate
        popup = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow {
            if win == dashboardWindow { dashboardWindow = nil }
            if win == settingsWindow { settingsWindow = nil }
        }
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}

// MARK: - 悬浮组件（置顶迷你卡：24h KPI + Top 工具 + 额度剩余一行）

fileprivate struct FloatWidgetView: View {
    @ObservedObject var state: AppState

    private var quotaLine: String? {
        guard let acct = state.quota.accounts.first(where: { $0.available }),
              let w = acct.windows.first,
              let p = w.percentage ?? w.usedPercent else { return nil }
        return "\(acct.label) 剩余 \(Int(max(0, 100 - p)))%"
    }

    var body: some View {
        let main = state.h24Overview()
        let top = state.h24TopTools()
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("⚡ 近 24 小时")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.muted)
                Spacer()
                if state.snapshot.refreshing {
                    Text("解析中…").font(.system(size: 9)).foregroundColor(Theme.warn)
                }
            }
            Text(Fmt.tokens(main.totalTokens))
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
            HStack(spacing: 10) {
                Label("\(Fmt.int(main.calls)) 次调用", systemImage: "doc.plaintext")
                if let c = main.totalCost {
                    Label(Fmt.cost(c), systemImage: "dollarsign.circle")
                }
            }
            .font(.system(size: 10.5))
            .foregroundColor(Theme.muted)
            if !top.isEmpty {
                Divider().overlay(Theme.border)
                ForEach(top, id: \.name) { item in
                    HStack {
                        Text(item.name).font(.system(size: 11)).lineLimit(1)
                        Spacer()
                        Text(Fmt.tokens(item.tokens))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundColor(Theme.muted)
                    }
                }
            }
            if let line = quotaLine {
                Divider().overlay(Theme.border)
                Text(line).font(.system(size: 10.5)).foregroundColor(Theme.muted)
            }
        }
        .padding(14)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.bg)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border)))
    }
}

// MARK: - 灵动岛（顶部居中胶囊：今日用量 + 首个可用账号剩余额度）

fileprivate struct NotchPillView: View {
    @ObservedObject var state: AppState

    private var todayTokens: Double {
        let midnight = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        return state.snapshot.rows.filter { $0.ts >= midnight }.reduce(0) { $0 + rowTokens($1) }
    }

    private var quotaLine: String? {
        guard let acct = state.quota.accounts.first(where: { $0.available }),
              let w = acct.windows.first,
              let p = w.percentage ?? w.usedPercent else { return nil }
        return "\(acct.label) 剩余 \(Int(max(0, 100 - p)))%"
    }

    var body: some View {
        HStack(spacing: 12) {
            Text("⚡").font(.system(size: 13))
            Text("今日 \(Fmt.tokens(todayTokens))")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
            if let line = quotaLine {
                Text(line)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Capsule().fill(Theme.bg)
            .overlay(Capsule().strokeBorder(Theme.border)))
    }
}
