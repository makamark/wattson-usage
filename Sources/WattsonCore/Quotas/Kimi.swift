// Quotas/Kimi.swift — Kimi 订阅额度（移植 CodexBar KimiUsageFetcher 的 Code API 口径）：
// 凭据 = env KIMI_CODE_API_KEY 或 ~/.kimi-code/credentials/kimi-code.json（须未过期）；
// GET {base}/coding/v1/usages，头 Bearer + X-Msh-Platform: kimi_code_cli；
// usage.detail = 周额度（绝对值），limits[0].detail = 速率窗口。
import Foundation

public struct KimiAuth: Sendable, Equatable {
    public var token: String
    public var baseUrl: String
    public init(token: String, baseUrl: String) {
        self.token = token
        self.baseUrl = baseUrl
    }
}

/// Kimi 会员档位 → 展示名（对齐 CodexBar KimiCodeAPIUsageResponse.User.Membership）
public func kimiPlanName(level: String?) -> String? {
    switch level?.trimmingCharacters(in: .whitespaces).uppercased() {
    case "LEVEL_FREE": return "Adagio"
    case "LEVEL_TRIAL": return "Andante"
    case "LEVEL_BASIC": return "Moderato"
    case "LEVEL_INTERMEDIATE": return "Allegretto"
    case "LEVEL_ADVANCED": return "Allegro"
    default: return level?.trimmingCharacters(in: .whitespaces).emptyToNil()
    }
}

/// 凭据：env KIMI_CODE_API_KEY 优先；其次 ~/.kimi-code/credentials/kimi-code.json（expires_at 须 > now+60s）
public func readKimiAuth(_ home: String, _ env: [String: String], now: Double = Date.nowMs()) -> KimiAuth? {
    let baseUrl = (env["KIMI_CODE_BASE_URL"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() } ?? "https://api.kimi.com")
        .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    if let envToken = env["KIMI_CODE_API_KEY"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return KimiAuth(token: envToken.trimmingCharacters(in: .whitespaces), baseUrl: baseUrl)
    }
    let codeHome = env["KIMI_CODE_HOME"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() }
        ?? (home as NSString).appendingPathComponent(".kimi-code")
    guard let parsed = parseJSONFile((codeHome as NSString).appendingPathComponent("credentials/kimi-code.json")) else { return nil }
    guard let token = quotaStr(parsed["access_token"]) else { return nil }
    guard let expiresAt = quotaNum(parsed["expires_at"]), expiresAt > now / 1000 + 60 else { return nil }
    return KimiAuth(token: token, baseUrl: baseUrl)
}

/// detail 结构：limit/used/remaining 可能是字符串数字；resetTime 兼容 reset_time/reset_at 蛇形
func windowFromDetail(key: String, label: String, raw: JSON?) -> QuotaWindow? {
    guard let d = raw?.obj else { return nil }
    let total = quotaNum(d["limit"])
    let used = quotaNum(d["used"])
    let remaining = quotaNum(d["remaining"])
    let percentage = percentOf(used, total)
    let resetAt = toEpochMs(d["resetTime"] ?? d["reset_time"] ?? d["reset_at"])
    if percentage == nil && resetAt == nil { return nil }
    return QuotaWindow(key: key, label: label, total: total, used: used, remaining: remaining,
                       percentage: percentage, nextResetAt: resetAt)
}

public func fetchKimiAccount(_ auth: KimiAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers: [String: String] = [
        "authorization": "Bearer \(auth.token)",
        "accept": "application/json",
        "x-msh-platform": "kimi_code_cli",
        "user-agent": "wattson-usage",
    ]
    do {
        let result = try await quotaFetchJson(doFetch, "\(auth.baseUrl)/coding/v1/usages", headers: headers)
        let root = result.body
        // TS 侧 (root['usage'] ?? null)：缺失或显式 null 都归一为 nil
        let usage = root["usage"].flatMap { $0.isNull ? nil : $0 }
        let rateLimit = root["limits"]?.arr?.first
        let membership = root["user"]?["membership"]
        var windows: [QuotaWindow] = []
        if let week = windowFromDetail(key: "week", label: "周额度", raw: usage) {
            windows.append(week)
        }
        if let rate = rateLimit.flatMap({ windowFromDetail(key: "rate", label: "速率限制", raw: $0["detail"]) }) {
            windows.append(rate)
        }
        return finalizeAccount(kind: .kimi, label: "Kimi",
                               planName: kimiPlanName(level: quotaStr(membership?["level"])),
                               windows: windows, anySuccess: usage != nil, now: now)
    } catch {
        return finalizeAccount(kind: .kimi, label: "Kimi",
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func kimiAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readKimiAuth(home, env, now: now) else { return missingAccount(.kimi, "Kimi", now) }
    return await fetchKimiAccount(auth, doFetch, now)
}
