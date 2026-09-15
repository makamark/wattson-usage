// AppState.swift — App 状态：采集器 + 额度轮询 + 本机 API 服务的编排。
// 配置口径：WATTSON_CONFIG 指向 agg.config.json（默认 ~/wattson/agg.config.json），
// WATTSON_PORT / WATTSON_REFRESH_MIN 环境变量覆盖文件值。
import WattsonCore
import Foundation
import AppKit
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var snapshot = Snapshot()
    @Published private(set) var quota = QuotaSnapshot(accounts: [])
    @Published private(set) var refreshing = false
    @Published private(set) var proxyNote: String?

    let collector: Collector
    let poller: QuotaPoller
    private var server: AggServer?
    private var timer: Any?

    let port: Int
    let refreshMinutes: Double
    let configPath: String

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
        let instanceId = UUID().uuidString
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
