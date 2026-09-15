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
    /// API 服务启动失败原因（如端口被外部实例占用）；nil = 正常监听
    @Published private(set) var serverError: String?
    /// 状态栏小窗的统计范围（popup.html sel-range，默认 24h）
    @Published var popupRange: RangeOption = .h24
    /// 看板全局筛选（web/src/state.ts filters，默认 30d × model × tokens）
    @Published var filters = DashboardFilters()

    /// 打开设置窗口的回调（AppDelegate 注入；主面板齿轮与状态栏右键共用）；
    /// 参数 = 打开后定位到的分页（nil = 默认通用页）
    var openSettingsHandler: ((SettingsPage?) -> Void)?
    func requestOpenSettings(_ page: SettingsPage? = nil) { openSettingsHandler?(page) }

    // MARK: 多设备管理（原向导 wizard 的核心逻辑）

    struct RemoteDevice: Identifiable {
        var id = UUID()
        var name: String
        var ssh: String
    }

    @Published private(set) var remoteDevices: [RemoteDevice] = []

    /// 从 agg.config.json 读取当前远端设备列表
    func loadDevices() {
        guard let obj = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: configPath)))) as? [String: Any] else { return }
        let devices = (obj["devices"] as? [[String: Any]]) ?? []
        remoteDevices = devices.compactMap { d in
            guard d["local"] == nil, let name = d["name"] as? String, let ssh = d["ssh"] as? String else { return nil }
            return RemoteDevice(name: name, ssh: ssh)
        }
    }

    struct SshProbe: Equatable {
        var running = false
        var ok = false
        var done = false
        var tools: [String] = []
        var missing: [String] = []
        var error: String?
    }

    @Published var sshProbe = SshProbe()

    /// SSH 探测（原 main.ts probeSsh 同口径）：远端打印 src:/missing: 行
    func probeSsh(dest: String) {
        sshProbe = SshProbe(running: true)
        let script = #"[ -e "$HOME/.zcode/cli/db/db.sqlite" ] && echo src:zcode; [ -d "$HOME/.codex/sessions" ] && echo src:codex; [ -e "$HOME/.workbuddy/workbuddy.db" ] && echo src:workbuddy; command -v sqlite3 >/dev/null || echo missing:sqlite3; command -v rsync >/dev/null || echo missing:rsync; true"#
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            p.arguments = ["-n", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", dest, script]
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            var result = SshProbe(running: false)
            do {
                try p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                guard p.terminationStatus == 0 else {
                    result.error = "ssh 不可达（需免密登录，检查 ~/.ssh/config）"
                    DispatchQueue.main.async { self.sshProbe = result }
                    return
                }
                let text = String(data: data, encoding: .utf8) ?? ""
                for line in text.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("src:") { result.tools.append(String(l.dropFirst(4))) }
                    if l.hasPrefix("missing:") { result.missing.append(String(l.dropFirst(8))) }
                }
                result.ok = true
                result.done = true
            } catch {
                result.error = "ssh 启动失败：\(error.localizedDescription)"
                result.done = true
            }
            DispatchQueue.main.async { self.sshProbe = result }
        }
    }

    /// 保存远端设备列表：写 agg.config.json devices 节（保留 server 节）+ 派生 devices.json
    func saveDevices(_ remotes: [RemoteDevice]) {
        remoteDevices = remotes
        let path = configPath
        var obj: [String: Any] = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: path)))) as? [String: Any] ?? [:]
        var devices: [[String: Any]] = [["name": collector.localHost, "local": true]]
        devices.append(contentsOf: remotes.map { ["name": $0.name, "ssh": $0.ssh] })
        obj["devices"] = devices
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        deriveDevicesFile()
    }

    /// devices.json 派生（原 scripts/gen-config.py 同口径：远端镜像根 → 设备根声明）
    private func deriveDevicesFile() {
        let outDir = ((NSHomeDirectory() as NSString).appendingPathComponent(".config/wattson"))
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        var roots: [[String: String]] = []
        for d in remoteDevices {
            roots.append([
                "host": d.name,
                "zcodeDb": "~/wattson/mirror/\(d.name)/zcode/db.sqlite",
                "codexHome": "~/wattson/mirror/\(d.name)/codex",
                "workbuddyDb": "~/wattson/mirror/\(d.name)/workbuddy/db.sqlite",
            ])
        }
        if let data = try? JSONSerialization.data(withJSONObject: roots, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: outDir + "/devices.json"))
        }
    }

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
        do { try s.start() } catch {
            serverError = "API 服务启动失败（端口 \(serverPort) 可能被占用，如 launchd 常驻实例）：\(errText(error))"
        }

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
        do { try s.start(); serverError = nil } catch {
            serverError = "API 服务启动失败（端口 \(port) 可能被占用）：\(errText(error))"
        }
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
            // 同步 → 采集依赖链：一轮完整结束后触发一次后台重解析，
            // 否则刚拉回的远端数据要等下一个采集节拍才进看板
            if p.terminationStatus == 0 {
                DispatchQueue.main.async { Task { await self.refreshNow() } }
            }
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

extension AppState.RemoteDevice: Equatable {
    static func == (l: AppState.RemoteDevice, r: AppState.RemoteDevice) -> Bool {
        l.name == r.name && l.ssh == r.ssh
    }
}
