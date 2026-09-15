// App.swift — Wattson 原生菜单栏 App：状态栏小窗（window 态）+ 完整看板窗口 + 本机 API 服务。
import WattsonCore
import SwiftUI

@main
struct WattsonAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            PopupView(state: appState) {
                openWindow(id: "dashboard")
                NSApp.activate(ignoringOtherApps: true)
            }
        } label: {
            Text(appState.menuTitle)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Wattson · AI 用量看板", id: "dashboard") {
            DashboardView(state: appState)
        }
        .defaultSize(width: 1180, height: 800)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
