// main.swift — wattson-server 无头入口：采集器 + 额度轮询 + 127.0.0.1 API 服务。
// 与原生 App 共用 WattsonCore；适合 launchd 常驻或无 GUI 的中心机部署。
// 启动次序：首次（可能较慢的冷）刷新完成后再监听端口，启动日志里的记录数即真实值。
import Foundation
import WattsonCore

let env = ProcessInfo.processInfo.environment
let dataDir = (env["WATTSON_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (NSHomeDirectory() as NSString).appendingPathComponent("wattson"))
let configPath = env["WATTSON_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
    ?? (dataDir as NSString).appendingPathComponent("agg.config.json")

let fileConfig: FileConfig
do {
    fileConfig = try loadFileConfig(configPath)
} catch {
    let message = (error as? ConfigError)?.message ?? String(describing: error)
    FileHandle.standardError.write(Data("[wattson-server] \(message)\n".utf8))
    exit(1)
}

func envNumber(_ name: String, _ fallback: Double, min: Double, max: Double) -> Double {
    guard let raw = env[name], !raw.isEmpty, let n = Double(raw), n >= min, n <= max else {
        return fallback
    }
    return n
}

let port = Int(envNumber("WATTSON_PORT", fileConfig.port ?? 8317, min: 1, max: 65535))
let refreshMinutes = envNumber("WATTSON_REFRESH_MIN", fileConfig.refreshMinutes ?? 30, min: 1, max: 24 * 60)
let instanceId = UUID().uuidString

let (quotaFetch, proxyUrl) = createQuotaFetch(env: env)
if let proxyUrl { print("[wattson-server] 额度出网代理：\(proxyUrl)") }

let collector = Collector()
let quotaPoller = QuotaPoller(env: env, fetchImpl: quotaFetch)

// 并发/排队语义：采集中再收到刷新请求不丢弃，记一个待办，本轮结束后补跑一次
final class RefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var refreshing = false
    private var pending = false
    func run(_ body: () async -> Void) async {
        lock.lock()
        if refreshing { pending = true; lock.unlock(); return }
        refreshing = true
        lock.unlock()
        await body()
        lock.lock()
        refreshing = false
        let again = pending
        pending = false
        lock.unlock()
        if again { await run(body) }
    }
}
let gate = RefreshGate()
let c = collector
let p = quotaPoller
let refreshOnce: () async -> Void = {
    await gate.run {
                _ = await c.refresh()
                _ = await p.current()
            }
}

let server = AggServer(port: port, collector: collector, quotaPoller: quotaPoller,
                       instanceId: instanceId, configPath: configPath,
                       refreshTrigger: { Task { await refreshOnce() } })

await refreshOnce()
let refreshTimer = DispatchSource.makeTimerSource(queue: .main)
refreshTimer.schedule(deadline: .now() + refreshMinutes * 60, repeating: refreshMinutes * 60)
refreshTimer.setEventHandler { Task { await refreshOnce() } }
refreshTimer.resume()
let quotaTimer = DispatchSource.makeTimerSource(queue: .main)
quotaTimer.schedule(deadline: .now() + 60, repeating: 60)
quotaTimer.setEventHandler { Task { _ = await quotaPoller.current() } }
quotaTimer.resume()

var signalSources: [DispatchSourceSignal] = []
try server.start()
print("[wattson-server/\(WATTSON_VERSION)] http://127.0.0.1:\(port)  records=\(collector.snapshot.rows.count)  localHost=\(collector.localHost)  refresh=\(Int(refreshMinutes))min  config=\(configPath)")

// 常驻：挂起直到收到 SIGINT/SIGTERM（async 顶层不能调 dispatchMain）
await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
    var resumed = false
    let handler: @Sendable () -> Void = {
        if !resumed { resumed = true; cont.resume() }
    }
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        signalSources.append(source)
    }
}
server.stop()
exit(0)
