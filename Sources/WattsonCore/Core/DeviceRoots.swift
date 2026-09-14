// Core/DeviceRoots.swift — devices.json 多设备数据根。
// 聚合器把各设备的 provider 数据镜像在一棵目录树下（如 ~/wattson/mirror/<host>/zcode/db.sqlite）。
// devices.json 声明哪些磁盘路径属于哪台远端主机，使会话数据能归属到设备：
//   [{ "host": "macpro", "zcodeDb": "~/wattson/mirror/macpro/zcode/db.sqlite",
//      "codexHome": "~/wattson/mirror/macpro/codex", "workbuddyDb": "..." }]
// zcode/workbuddy 源缓存键形如 `<dbPath>:<sessionId>`（冒号后缀），codex 源是其
// home 目录下的文件路径，两种形状都要前缀匹配。配置缺失/非法不是错误：一律归属本机。
import Foundation

public struct DeviceRoot: Sendable, Equatable {
    public var host: String
    public var zcodeDb: String?
    public var codexHome: String?
    public var workbuddyDb: String?

    public init(host: String, zcodeDb: String? = nil, codexHome: String? = nil, workbuddyDb: String? = nil) {
        self.host = host
        self.zcodeDb = zcodeDb
        self.codexHome = codexHome
        self.workbuddyDb = workbuddyDb
    }
}

public func devicesFile(env: [String: String] = [:]) -> String {
    if let f = env["WATTSON_DEVICES_FILE"], !f.isEmpty { return f }
    return ((homePath() as NSString).appendingPathComponent(".config/wattson")) + "/devices.json"
}

/// 读取 devices.json（文件缺省/损坏 → 空数组）。进程内很少变化，直接每次读取。
public func loadDeviceRoots(env: [String: String] = [:]) -> [DeviceRoot] {
    let file = devicesFile(env: env)
    guard let parsed = parseJSONFile(file), let list = parsed.arr else { return [] }
    return list.compactMap { item in
        guard let obj = item.obj, let host = obj["host"]?.str else { return nil }
        let resolve = { (p: JSON?) -> String? in
            guard let raw = p?.str, !raw.isEmpty else { return nil }
            return (expandHome(raw) as NSString).standardizingPath
        }
        return DeviceRoot(host: host, zcodeDb: resolve(obj["zcodeDb"]),
                          codexHome: resolve(obj["codexHome"]),
                          workbuddyDb: resolve(obj["workbuddyDb"]))
    }
}

/// 源路径 → 设备名：命中任一远端根前缀则归属该主机，否则本机
public func hostForSourcePath(_ path: String, roots: [DeviceRoot], localHost: String) -> String {
    for d in roots {
        for root in [d.zcodeDb, d.codexHome, d.workbuddyDb].compactMap({ $0 }) {
            if path == root || path.hasPrefix(root + "/") || path.hasPrefix(root + ":") {
                return d.host
            }
        }
    }
    return localHost
}
