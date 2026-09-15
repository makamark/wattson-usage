// AppState.swift — App 状态：采集器 + 额度轮询 + 本机 API 服务的编排。
// 配置口径：WATTSON_CONFIG 指向 agg.config.json（默认 ~/wattson/agg.config.json），
// WATTSON_PORT / WATTSON_REFRESH_MIN 环境变量覆盖文件值。
import WattsonCore
import Foundation
import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var quota = QuotaSnapshot(accounts: [])
    @Published private(set) var refreshing = false
    @Published private(set) var proxyNote: String?
    /// 状态栏小窗的统计范围（popup.html sel-range，默认 24h）
    @Published var popupRange: RangeOption = .h24
    /// 看板全局筛选（web/src/state.ts filters，默认 30d × model × tokens）
    @Published var filters = DashboardFilters()

    /// 打开设置窗口的回调（AppDelegate 注入；主面板齿轮与状态栏右键共用）
    var openSettingsHandler: (() -> Void)?
    func requestOpenSettings() { openSettingsHandler?() }

    let collector: Collector
    let poller: QuotaPoller
    private var server: AggServer?
    private var timer: Any?
    private var mirrorRunning = false

    var port: Int
    var refreshMinutes: Double
    let configPath: String
    let instanceId = UUID().uuidString

    var menuTitle: String {
        let tokens = snapshot.rows
            .filter { $0.ts >= Date.nowMs() - 24 * 3600 * 1000 }
            .reduce(0.0) { $0 + rowTokens($1) }
        return tokens > 0 ? "⚡ \(formatTokens(tokens))" : "⚡"
    }

    init() {
        let env = ProcessInfo.processInfo.environment
        let dataDir = env["WATTSON_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("wattson")
        configPath = env["WATTSON_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (dataDir as NSString).appendingPathComponent("agg.config.json")
        let fileConfig = (try? loadFileConfig(configPath)) ?? FileConfig()

        func envNumber(_ name: String, _ fallback: Double) -> Double {
            guard let raw = env[name], !raw.isEmpty, let v = Double(raw), v > 0 else { return fallback }
            return v
        }
        port = Int(envNumber("WATTSON_PORT", fileConfig.port ?? 8317))
        refreshMinutes = envNumber("WATTSON_REFRESH_MIN", fileConfig.refreshMinutes ?? 30)

        let (quotaFetch, proxyUrl) = createQuotaFetch(env: env)
        proxyNote = proxyUrl.map { "额度出网代理：\($0)" }
        collector = Collector()
        poller = QuotaPoller(env: env, fetchImpl: quotaFetch)

        let c = collector
        let p = poller
        let cfg = configPath
        let serverPort = port
        let trigger: () -> Void = { Task { _ = await c.refresh(); _ = await p.current() } }
        let s = AggServer(port: serverPort, collector: c, quotaPoller: p,
                          instanceId: instanceId, configPath: cfg, refreshTrigger: trigger)
        server = s
        try? s.start()

        Task { await refreshNow() }
        scheduleQuotaPoll()
        scheduleRefresh()
    }

    func refreshNow() async {
        refreshing = true
        _ = await collector.refresh()
        snapshot = collector.snapshot
        refreshing = false
    }

    func pollQuotaNow() async {
        quota = await poller.current()
    }

    // MARK: 设置应用与服务器重启（主面板设置页）

    /// 保存 agg.config.json（保留 devices 节）并重启 API 服务
    func applySettings(port newPort: Int, refreshMinutes newRefresh: Double) {
        let path = configPath
        var obj: [String: Any] = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
        var serverSection = obj["server"] as? [String: Any] ?? [:]
        serverSection["port"] = newPort
        serverSection["refreshMinutes"] = Int(newRefresh)
        obj["server"] = serverSection
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        port = newPort
        refreshMinutes = newRefresh
        restartServer()
    }

    private func restartServer() {
        server?.stop()
        let c = collector
        let p = poller
        let cfg = configPath
        let id = instanceId
        let trigger: () -> Void = { Task { _ = await c.refresh(); _ = await p.current() } }
        let s = AggServer(port: port, collector: c, quotaPoller: p,
                          instanceId: id, configPath: cfg, refreshTrigger: trigger)
        try? s.start()
        server = s
    }

    // MARK: 状态栏右键动作

    /// 立即同步远端：跑打包内置的 mirror.sh（AGG_CONFIG 指向当前配置），日志追加到 mirror.log
    func runMirrorNow() {
        guard !mirrorRunning else { return }
        guard let script = Bundle.module.path(forResource: "mirror", ofType: "sh", inDirectory: "Resources")
        else { return }
        mirrorRunning = true
        let configPath = self.configPath
        let dataDir = ((NSHomeDirectory() as NSString).appendingPathComponent("wattson"))
        let logPath = (dataDir as NSString).appendingPathComponent("mirror.log")
        DispatchQueue.global(qos: .utility).async {
            defer { DispatchQueue.main.async { self.mirrorRunning = false } }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script]
            var env = ProcessInfo.processInfo.environment
            env["AGG_CONFIG"] = configPath
            env["MIRROR_BASE"] = (dataDir as NSString).appendingPathComponent("mirror")
            p.environment = env
            if !FileManager.default.fileExists(atPath: logPath) {
                FileManager.default.createFile(atPath: logPath, contents: nil)
            }
            let handle = FileHandle(forWritingAtPath: logPath)
            defer { try? handle?.close() }
            if let handle {
                let stamp = "\n[mirror] 手动同步 \(Date())\n"
                handle.seekToEndOfFile()
                handle.write(stamp.data(using: .utf8)!)
                p.standardOutput = handle
                p.standardError = handle
            }
            try? p.run()
            p.waitUntilExit()
        }
    }

    var isMirrorRunning: Bool { mirrorRunning }

    var loginItemEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func toggleLoginItem() {
        switch SMAppService.mainApp.status {
        case .enabled: try? SMAppService.mainApp.unregister()
        default: try? SMAppService.mainApp.register()
        }
    }

    func openLogFile() {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent("wattson")
        let log = (dir as NSString).appendingPathComponent("server.log")
        if FileManager.default.fileExists(atPath: log) {
            NSWorkspace.shared.open(URL(fileURLWithPath: log))
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }

    private func scheduleQuotaPoll() {
        Task { await pollQuotaNow() }
        let t = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.pollQuotaNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func scheduleRefresh() {
        let t = Timer.scheduledTimer(withTimeInterval: refreshMinutes * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refreshNow() }
        }
        RunLoop.main.add(t, forMode: .common)
    }
}

func formatTokens(_ n: Double) -> String {
    if n >= 1e9 { return String(format: "%.2fB", n / 1e9) }
    if n >= 1e6 { return String(format: "%.2fM", n / 1e6) }
    if n >= 1e3 { return String(format: "%.1fK", n / 1e3) }
    return String(format: "%.0f", n)
}
