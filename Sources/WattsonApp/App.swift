// App.swift — Wattson 原生菜单栏 App：菜单栏入口 + 完整看板窗口 + 本机 API 服务。
import WattsonCore
import SwiftUI

@main
struct WattsonAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra(appState.menuTitle, isInserted: .constant(true)) {
            Button("打开看板") { appState.openDashboard() }
            Button(appState.refreshing ? "采集中…" : "立即刷新") {
                Task { await appState.refreshNow() }
            }
            .disabled(appState.refreshing)
            Divider()
            ForEach(appState.quota.accounts, id: \.self) { account in
                let text = quotaMenuItemText(account)
                if let text {
                    Text(text).disabled(true)
                }
            }
            Divider()
            Button("退出 Wattson") { NSApp.terminate(nil) }
        }
        .menuBarExtraStyle(.menu)

        WindowGroup("Wattson 看板", id: "dashboard") {
            DashboardView(state: appState)
        }
        .defaultSize(width: 1180, height: 780)
    }
}

/// 配额菜单项文案（不可用的账号不占菜单）
func quotaMenuItemText(_ a: QuotaAccount) -> String? {
    guard a.available, let window = a.windows.first else { return nil }
    let percent = window.percentage.map { String(format: "%.0f%%", $0) } ?? "—"
    return "\(a.label)：\(percent) 已用"
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
