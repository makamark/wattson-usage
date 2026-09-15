// App.swift — Wattson 原生菜单栏 App（AppKit 托管 + SwiftUI 视图）。
// 状态栏图标：左键弹状态栏小窗（原 popup 语义），右键弹菜单
// （打开完整看板 / 刷新数据 / 设置… / 立即同步远端 / 登录时启动 / 查看日志… / 退出），
// 与原 Electron 托盘行为一一对应。看板窗口由本类托管，设置入口整合在主面板侧栏。
import WattsonCore
import SwiftUI
import AppKit
import Combine
import ServiceManagement

@main
struct WattsonAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var popup: NSPopover?
    private var dashboardWindow: NSWindow?
    private var cancellable: AnyCancellable?
    private var lastPopupHideAt: TimeInterval = 0
    private var mirrorProcessRunning = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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

        let quit = NSMenuItem(title: "退出 Wattson", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil) // 以图标为锚弹出菜单
        statusItem?.menu = nil                // 菜单关闭后恢复左键行为
    }

    @objc private func menuOpenDashboard() { openDashboard() }
    @objc private func menuRefresh() { Task { await appState.refreshNow() } }
    @objc private func menuOpenSettings() {
        appState.showDashboardSettings = true
        openDashboard()
    }
    @objc private func menuSyncRemote() { appState.runMirrorNow() }
    @objc private func menuToggleLoginItem() { appState.toggleLoginItem() }
    @objc private func menuOpenLogFile() { appState.openLogFile() }

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

    // MARK: NSPopoverDelegate / NSWindowDelegate

    func popoverDidClose(_ notification: Notification) {
        lastPopupHideAt = Date.timeIntervalSinceReferenceDate
        popup = nil
    }

    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow, win == dashboardWindow {
            dashboardWindow = nil
        }
    }

    private var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
