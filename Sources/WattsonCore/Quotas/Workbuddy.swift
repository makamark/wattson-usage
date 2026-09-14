// Quotas/Workbuddy.swift — WorkBuddy 订阅额度（参考 cockpit-tools workbuddy_oauth.rs）：
// POST https://copilot.tencent.com/v2/billing/meter/get-user-resource，
// 头 Authorization: Bearer + X-User-Id / X-Enterprise-Id / X-Tenant-Id / X-Domain。
// 响应是腾讯云计费形态：data.Response.Data.Accounts[].CycleCapacity{Size,Used,Remain}。
// 注意：WorkBuddy IDE 本体把 token 存在 macOS 钥匙串（不做无感读取），
// 本模块支持 env（WORKBUDDY_ACCESS_TOKEN…）或凭据文件 ~/wattson/workbuddy-auth.json。
import Foundation

public struct WorkbuddyAuth: Sendable, Equatable {
    public var token: String
    public var uid: String?
    public var enterpriseId: String?
    public var domain: String?
    public init(token: String, uid: String?, enterpriseId: String?, domain: String?) {
        self.token = token
        self.uid = uid
        self.enterpriseId = enterpriseId
        self.domain = domain
    }
}

private let defaultHost = "https://copilot.tencent.com"

/// 凭据：env WORKBUDDY_ACCESS_TOKEN(+WORKBUDDY_UID/WORKBUDDY_ENTERPRISE_ID/WORKBUDDY_DOMAIN)
/// 优先，其次 ~/wattson/workbuddy-auth.json（accessToken/access_token + uid/enterpriseId/domain）
public func readWorkbuddyAuth(_ home: String, _ env: [String: String]) -> WorkbuddyAuth? {
    if let envToken = env["WORKBUDDY_ACCESS_TOKEN"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return WorkbuddyAuth(
            token: envToken.trimmingCharacters(in: .whitespaces),
            uid: env["WORKBUDDY_UID"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() },
            enterpriseId: env["WORKBUDDY_ENTERPRISE_ID"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() },
            domain: env["WORKBUDDY_DOMAIN"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() })
    }
    guard let parsed = parseJSONFile((home as NSString).appendingPathComponent("wattson/workbuddy-auth.json")) else { return nil }
    guard let token = quotaStr(parsed["accessToken"]) ?? quotaStr(parsed["access_token"]) ?? quotaStr(parsed["token"]) else { return nil }
    return WorkbuddyAuth(
        token: token,
        uid: quotaStr(parsed["uid"]),
        enterpriseId: quotaStr(parsed["enterpriseId"]) ?? quotaStr(parsed["enterprise_id"]),
        domain: quotaStr(parsed["domain"]))
}

func authHeaders(_ auth: WorkbuddyAuth) -> [String: String] {
    var headers: [String: String] = [
        "authorization": "Bearer \(auth.token)",
        "content-type": "application/json",
        "accept": "application/json, text/plain, */*",
    ]
    if let uid = auth.uid { headers["x-user-id"] = uid }
    if let enterpriseId = auth.enterpriseId {
        headers["x-enterprise-id"] = enterpriseId
        headers["x-tenant-id"] = enterpriseId
    }
    if let domain = auth.domain { headers["x-domain"] = domain }
    return headers
}

/// 腾讯云资源包 → 统一窗口：CycleCapacity{Size,Used,Remain} + CycleEndTime/ResetTime
public func workbuddyWindows(resourceBody: JSON) -> [QuotaWindow] {
    guard let accounts = resourceBody["data"]?["Response"]?["Data"]?["Accounts"]?.arr else { return [] }
    var windows: [QuotaWindow] = []
    for account in accounts {
        guard let a = account.obj else { continue }
        let total = quotaNum(a["CycleCapacitySize"]) ?? quotaNum(a["CapacitySize"])
        let used = quotaNum(a["CycleCapacityUsed"]) ?? quotaNum(a["CapacityUsed"])
        let remain = quotaNum(a["CycleCapacityRemain"]) ?? quotaNum(a["CapacityRemain"])
        let unlimited = a["Unlimited"]?.bool == true
        if total == nil && used == nil && !unlimited { continue }
        windows.append(QuotaWindow(
            key: "cycle",
            label: unlimited ? "周期额度（不限量）" : "周期额度",
            total: total,
            used: used,
            remaining: unlimited ? nil : (remain ?? max(0, (total ?? 0) - (used ?? 0))),
            percentage: unlimited ? 0 : percentOf(used, total),
            nextResetAt: toEpochMs(a["CycleEndTime"] ?? a["CycleResetTime"] ?? a["CycleStartTime"])))
    }
    return windows
}

public func fetchWorkbuddyAccount(
    _ auth: WorkbuddyAuth, _ doFetch: FetchLike, _ now: Double,
    host: String = "https://copilot.tencent.com",
) async -> QuotaAccount {
    let headers = authHeaders(auth)
    do {
        let result = try await quotaFetchJson(doFetch, "\(host)/v2/billing/meter/get-user-resource",
                                              method: "POST", headers: headers, body: "{}")
        let windows = workbuddyWindows(resourceBody: result.body)
        return finalizeAccount(kind: .workbuddy, label: "WorkBuddy",
                               windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .workbuddy, label: "WorkBuddy",
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func workbuddyAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readWorkbuddyAuth(home, env) else { return missingAccount(.workbuddy, "WorkBuddy", now) }
    let host = env["WORKBUDDY_API_HOST"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() } ?? defaultHost
    return await fetchWorkbuddyAccount(auth, doFetch, now, host: host)
}
