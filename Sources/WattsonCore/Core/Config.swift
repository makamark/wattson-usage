// Core/Config.swift — agg.config.json server 节解析；env 覆盖在入口。
// 配置文件路径可由 WATTSON_CONFIG 指定，默认 ~/wattson/agg.config.json。
// 语义：文件不存在 = 全默认（首次运行）；文件存在但损坏/字段非法 = 抛 ConfigError
// 让入口 fail-fast——坏配置静默当默认会掩盖端口/刷新间隔错乱。
import Foundation

public struct ConfigError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

public struct FileConfig: Equatable, Sendable {
    public var port: Double?
    public var refreshMinutes: Double?
    public var webDist: String?

    public init(port: Double? = nil, refreshMinutes: Double? = nil, webDist: String? = nil) {
        self.port = port
        self.refreshMinutes = refreshMinutes
        self.webDist = webDist
    }
}

func configNumText(_ v: JSON) -> String {
    if let n = v.num, n.truncatingRemainder(dividingBy: 1) == 0 { return String(Int64(n)) }
    if let s = v.str { return s }
    return String(describing: v)
}

public func loadFileConfig(_ file: String) throws -> FileConfig {
    let raw: String
    do {
        raw = try String(contentsOfFile: file, encoding: .utf8)
    } catch let e as NSError {
        // ENOENT = 全默认（首次运行）；其它读错误照实抛出
        if e.domain == NSCocoaErrorDomain, e.code == NSFileReadNoSuchFileError { return FileConfig() }
        if e.domain == NSPOSIXErrorDomain, e.code == 2 { return FileConfig() }
        throw e
    }
    guard let parsed = try? JSON.parse(raw) else {
        throw ConfigError("配置文件不是合法 JSON：\(file)")
    }
    guard let root = parsed.obj, !parsed.isNull else {
        throw ConfigError("配置文件顶层必须是对象：\(file)")
    }
    let serverNode = root["server"] ?? JSON.obj([:])
    guard let o = serverNode.obj else {
        throw ConfigError("配置 server 节必须是对象：\(file)")
    }
    var out = FileConfig()
    func intField(_ key: String, min: Double, max: Double) throws -> Double? {
        guard let v = o[key] else { return nil }
        let n = v.num
        guard let n, n.truncatingRemainder(dividingBy: 1) == 0, n >= min, n <= max else {
            throw ConfigError("配置 server.\(key) 必须是 \(Int64(min))–\(Int64(max)) 的整数，实际：\(configNumText(v))")
        }
        return n
    }
    if let port = try intField("port", min: 1, max: 65535) { out.port = port }
    if let refreshMinutes = try intField("refreshMinutes", min: 1, max: 24 * 60) { out.refreshMinutes = refreshMinutes }
    if let wd = o["webDist"] {
        guard let s = wd.str, !s.isEmpty else {
            throw ConfigError("配置 server.webDist 必须是非空字符串，实际：\(configNumText(wd))")
        }
        out.webDist = s
    }
    return out
}
