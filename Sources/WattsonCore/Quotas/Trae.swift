// Quotas/Trae.swift — Trae 订阅额度（参考 cockpit-tools
// trae_account_core_refresh.rs / trae_account_core_platform_storage.rs）：
// POST {origin}/trae/api/v1/pay/ide_user_pay_status 与 ide_user_ent_usage（require_usage），
// 头 Authorization: Bearer。origin 按区域：intl=grow-normal.trae.ai（备 growsg-normal.trae.ai），
// cn=grow-normal.trae.cn。响应包体 user_entitlement_pack_list[]，按 product_type 优先级
// [6,4,1,9,8,0] 取主包，重置时间在 entitlement_base_info.end_time（秒）。
// 注意：Trae IDE 本体把 token 存在 macOS 钥匙串（不做无感读取），
// 本模块支持 env（TRAE_ACCESS_TOKEN/TRAE_REGION）或凭据文件 ~/wattson/trae-auth.json。
import Foundation

public struct TraeAuth: Sendable, Equatable {
    public var token: String
    /// 'cn' | 'intl'
    public var region: String
    public init(token: String, region: String) {
        self.token = token
        self.region = region
    }
}

private let regionHosts: [String: [String]] = [
    "intl": ["https://grow-normal.trae.ai", "https://growsg-normal.trae.ai"],
    "cn": ["https://grow-normal.trae.cn", "https://grow-normal.trae.ai"],
]

/// 凭据：env TRAE_ACCESS_TOKEN(+TRAE_REGION=cn|intl) 优先，其次 ~/wattson/trae-auth.json
public func readTraeAuth(_ home: String, _ env: [String: String]) -> TraeAuth? {
    if let envToken = env["TRAE_ACCESS_TOKEN"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        let region = env["TRAE_REGION"].flatMap { $0.trimmingCharacters(in: .whitespaces) } == "cn" ? "cn" : "intl"
        return TraeAuth(token: envToken.trimmingCharacters(in: .whitespaces), region: region)
    }
    guard let parsed = parseJSONFile((home as NSString).appendingPathComponent("wattson/trae-auth.json")) else { return nil }
    guard let token = quotaStr(parsed["accessToken"]) ?? quotaStr(parsed["access_token"]) ?? quotaStr(parsed["token"]) else { return nil }
    return TraeAuth(token: token, region: parsed["region"]?.str == "cn" ? "cn" : "intl")
}

private let productTypeOrder: [Double] = [6, 4, 1, 9, 8, 0]

func packProductType(_ pack: JSON) -> Double? {
    quotaNum(pack["product_type"]) ?? quotaNum(pack["productType"])
}

/// 主资源包 → 窗口：数字字段名在响应中不完全稳定，做宽口径提取
func windowFromPack(_ pack: JSON) -> QuotaWindow {
    let total = quotaNum(pack["entitlement_total"]) ?? quotaNum(pack["total"]) ?? quotaNum(pack["limit"])
        ?? quotaNum(pack["capacity"]) ?? quotaNum(pack["CapacitySize"])
    let used = quotaNum(pack["entitlement_used"]) ?? quotaNum(pack["used"]) ?? quotaNum(pack["Usage"])
        ?? quotaNum(pack["used_num"]) ?? quotaNum(pack["CapacityUsed"])
    let remain = quotaNum(pack["entitlement_remain"]) ?? quotaNum(pack["remaining"]) ?? quotaNum(pack["remain"])
        ?? quotaNum(pack["CapacityRemain"])
    let resetAt = toEpochMs(
        pack["entitlement_base_info"]?["end_time"]
            ?? pack["end_time"] ?? pack["reset_time"])
    return QuotaWindow(
        key: "cycle", label: "周期额度",
        total: total, used: used, remaining: remain,
        percentage: percentOf(used, total),
        nextResetAt: resetAt)
}

public func traeWindows(usageBody: JSON) -> (windows: [QuotaWindow], planName: String?) {
    let list = usageBody["user_entitlement_pack_list"]?.arr
    var planName: String?
    var windows: [QuotaWindow] = []
    if let list, !list.isEmpty {
        let packs = list.filter { $0.obj != nil }
        func pick(_ type: Double) -> JSON? {
            packs.first { packProductType($0) == type }
        }
        let main = productTypeOrder.compactMap(pick).first
        if let main {
            windows.append(windowFromPack(main))
            planName = quotaStr(main["product_name"]) ?? quotaStr(main["plan_name"])
        }
    }
    return (windows, planName)
}

func postTrae(_ doFetch: FetchLike, _ origin: String, _ path: String, _ token: String, _ body: JSON) async throws -> (status: Int, body: JSON) {
    let payload = String(data: try body.encoded(), encoding: .utf8)
    return try await quotaFetchJson(doFetch, "\(origin)\(path)", method: "POST", headers: [
        "authorization": "Bearer \(token)",
        "content-type": "application/json",
        "accept": "application/json",
    ], body: payload)
}

public func fetchTraeAccount(_ auth: TraeAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let origins = regionHosts[auth.region] ?? []
    var lastErr: (any Error)?
    for origin in origins {
        do {
            let result = try await postTrae(doFetch, origin, "/trae/api/v1/pay/ide_user_ent_usage", auth.token,
                                            JSON.obj(["require_usage": .bool(true)]))
            let parsed = traeWindows(usageBody: result.body)
            return finalizeAccount(kind: .trae, label: "Trae",
                                   planName: parsed.planName, windows: parsed.windows, anySuccess: true, now: now)
        } catch {
            lastErr = error
            // 401/403 没必要换 origin 重试
            if readHttpStatus(error) == 401 || readHttpStatus(error) == 403 { break }
        }
    }
    return finalizeAccount(kind: .trae, label: "Trae",
                           error: lastErr.map(errText) ?? "no reachable origin",
                           httpStatus: lastErr.flatMap { readHttpStatus($0).map(Double.init) }, now: now)
}

public func traeAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readTraeAuth(home, env) else { return missingAccount(.trae, "Trae", now) }
    return await fetchTraeAccount(auth, doFetch, now)
}
