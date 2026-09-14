// Quotas/OpenRouter.swift — OpenRouter 额度（移植自原生实现 openrouter.js 插件口径）：
// 凭据 = env OPENROUTER_API_KEY；GET {base}/credits → data.total_credits/total_usage；
// 可选 GET {base}/key → 限额窗口（limit/limit_remaining/usage + limit_reset）。
import Foundation

private let LABEL = "OpenRouter"

/// 凭据：env OPENROUTER_API_KEY，可选 OPENROUTER_API_URL（默认官方 v1，去尾部斜杠）
public func readOpenRouterAuth(_ env: [String: String]) -> (token: String, baseUrl: String)? {
    guard let token = env["OPENROUTER_API_KEY"], !token.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    var baseUrl = env["OPENROUTER_API_URL"]?.trimmingCharacters(in: .whitespaces) ?? ""
    if baseUrl.isEmpty { baseUrl = "https://openrouter.ai/api/v1" }
    while baseUrl.hasSuffix("/") { baseUrl.removeLast() }
    return (token.trimmingCharacters(in: .whitespaces), baseUrl)
}

public func fetchOpenRouterAccount(_ auth: (token: String, baseUrl: String), _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "Bearer \(auth.token)",
        "x-title": "wattson-usage",
    ]
    do {
        let credits = try await quotaFetchJson(doFetch, "\(auth.baseUrl)/credits", headers: headers)
        let creditsData = credits.body["data"] ?? .null
        guard let totalCredits = quotaNum(creditsData["total_credits"]),
              let totalUsage = quotaNum(creditsData["total_usage"]) else {
            throw QuotaMessageError(message: "credits 响应缺少 total_credits/total_usage")
        }
        let balance = max(0, totalCredits - totalUsage)

        var windows: [QuotaWindow] = [
            QuotaWindow(key: "credits", label: "账户余额",
                        total: totalCredits, used: totalUsage, remaining: balance,
                        percentage: percentOf(totalUsage, totalCredits), nextResetAt: nil),
        ]

        // /key 是可选增强：失败不拖垮主快照
        if let key = try? await quotaFetchJson(doFetch, "\(auth.baseUrl)/key", headers: headers, timeoutMs: 5_000) {
            let keyData = key.body["data"] ?? .null
            if let limit = quotaNum(keyData["limit"]), limit > 0 {
                let limitRemaining = quotaNum(keyData["limit_remaining"])
                let keyUsed: Double
                if let lr = limitRemaining {
                    keyUsed = min(limit, max(0, limit - lr))
                } else {
                    keyUsed = min(limit, quotaNum(keyData["usage"]) ?? 0)
                }
                windows.append(QuotaWindow(key: "limit", label: "Key 限额",
                                           total: limit, used: keyUsed, remaining: max(0, limit - keyUsed),
                                           percentage: percentOf(keyUsed, limit), nextResetAt: nil))
            }
        }

        return finalizeAccount(kind: .openrouter, label: LABEL,
                               windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .openrouter, label: LABEL,
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func openrouterAccount(_ home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    // home 未用：OpenRouter 凭据只来自 env，仅为统一签名保留
    guard let auth = readOpenRouterAuth(env) else { return missingAccount(.openrouter, LABEL, now) }
    return await fetchOpenRouterAccount(auth, doFetch, now)
}
