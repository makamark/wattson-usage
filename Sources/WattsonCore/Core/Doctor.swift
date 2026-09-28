// Core/Doctor.swift — doctor 健康检查：只读检查项 + 报告渲染。
// CLI（wattson-server doctor）与 App 菜单（诊断…）共用同一套检查；
// 除数据目录的幂等创建（首次运行刷新也要建，属预期副作用）外无其他写入。
import Foundation

public struct DoctorCheck: Sendable, Equatable {
    public var name: String
    public var ok: Bool
    public var detail: String

    public init(name: String, ok: Bool, detail: String) {
        self.name = name
        self.ok = ok
        self.detail = detail
    }
}

public struct DoctorReport: Sendable, Equatable {
    public var checks: [DoctorCheck]
    public var allOk: Bool { checks.allSatisfy(\.ok) }

    public init(checks: [DoctorCheck]) { self.checks = checks }
}

public func doctorChecks(env: [String: String] = [:], configPath: String? = nil,
                         dataDir: String? = nil, home: String? = nil,
                         pricingPath: String? = nil, now: Date = Date()) -> DoctorReport {
    let fm = FileManager.default
    let homeDir = home ?? homePath()
    var checks: [DoctorCheck] = []

    // 1. 配置文件（不存在 = 全默认，属正常；存在但损坏才是故障）
    let cfgPath = configPath
        ?? env["WATTSON_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (homeDir as NSString).appendingPathComponent("wattson/agg.config.json")
    do {
        let cfg = try loadFileConfig(cfgPath)
        let port = cfg.port.map { String(Int($0)) } ?? "8317（默认）"
        let refresh = cfg.refreshMinutes.map { String(Int($0)) } ?? "30（默认）"
        checks.append(DoctorCheck(name: "配置文件", ok: true,
            detail: "\(cfgPath) 可读（port=\(port)，refresh=\(refresh)min）"))
    } catch {
        checks.append(DoctorCheck(name: "配置文件", ok: false,
            detail: "\(cfgPath)：\((error as? ConfigError)?.message ?? String(describing: error))"))
    }

    // 2. 多设备根（缺失/空 = 仅本机，属正常状态而非错误）
    let roots = loadDeviceRoots(env: env)
    if roots.isEmpty {
        checks.append(DoctorCheck(name: "多设备根", ok: true,
            detail: "\(devicesFile(env: env)) 未配置或为空（仅聚合本机）"))
    } else {
        checks.append(DoctorCheck(name: "多设备根", ok: true,
            detail: "\(roots.count) 台远端设备：\(roots.map(\.host).joined(separator: "、"))"))
    }

    // 3. 数据目录（可写性；创建目录是幂等的）
    let dir = dataDir
        ?? env["WATTSON_DATA_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (homeDir as NSString).appendingPathComponent("wattson")
    let dirOk = ((try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)) != nil)
        && fm.isWritableFile(atPath: dir)
    checks.append(DoctorCheck(name: "数据目录", ok: dirOk,
        detail: dirOk ? "\(dir) 可写" : "\(dir) 不可写（检查磁盘权限）"))

    // 4. 价目缓存（缺失/过期都不是故障：内嵌快照兜底，联网后自动刷新）
    let pricePath = pricingPath ?? pricingCachePath(home: homeDir)
    if let attrs = try? fm.attributesOfItem(atPath: pricePath),
       let mtime = attrs[.modificationDate] as? Date {
        let age = now.timeIntervalSince(mtime)
        let state = age < PRICING_CACHE_TTL ? "新鲜" : "已过期（下次刷新时在线更新）"
        checks.append(DoctorCheck(name: "价目缓存", ok: true,
            detail: "\(pricePath)（\(state)，\(Int(age / 3600)) 小时前更新）"))
    } else {
        checks.append(DoctorCheck(name: "价目缓存", ok: true,
            detail: "\(pricePath) 不存在（当前按内嵌快照计价，联网后自动补全）"))
    }

    // 5. 本机用量源（一个都没有 → 看板将为空，判未通过）
    let sources: [(String, String)] = [
        ("claude", (homeDir as NSString).appendingPathComponent(".claude")),
        ("codex", (homeDir as NSString).appendingPathComponent(".codex")),
        ("zcode", (homeDir as NSString).appendingPathComponent(".zcode/cli/db/db.sqlite")),
        ("workbuddy", (homeDir as NSString).appendingPathComponent(".workbuddy/workbuddy.db")),
    ]
    let found = sources.filter { fm.fileExists(atPath: $0.1) }.map(\.0)
    checks.append(DoctorCheck(name: "本机用量源", ok: !found.isEmpty,
        detail: found.isEmpty
            ? "未发现任何已知用量源（claude/codex/zcode/workbuddy），看板将为空"
            : "发现：\(found.joined(separator: "、"))"))

    return DoctorReport(checks: checks)
}

public func renderDoctorReport(_ report: DoctorReport, version: String = WATTSON_VERSION) -> String {
    var lines = ["Wattson doctor（v\(version)）"]
    for c in report.checks {
        lines.append("\(c.ok ? "✓" : "✗") \(c.name)：\(c.detail)")
    }
    lines.append(report.allOk ? "全部检查通过" : "存在未通过项（见 ✗）")
    return lines.joined(separator: "\n")
}
