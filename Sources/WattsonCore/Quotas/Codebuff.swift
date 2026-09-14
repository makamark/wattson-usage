// Quotas/Codebuff.swift — Codebuff 订阅额度（移植自原生实现 CodebuffUsageFetcher）：
// 凭据 = env CODEBUFF_API_KEY 或 ~/.config/manicode/credentials.json（codebuff login 写入）；
// POST {base}/api/v1/usage（注意是 POST）+ 可选 GET {base}/api/user/subscription。
import Foundation

public struct CodebuffAuth: Sendable, Equatable {
    public var token: String
    public var baseUrl: String
    public init(token: String, baseUrl: String) {
        self.token = token
        self.baseUrl = baseUrl
    }
}

/// 凭据：env CODEBUFF_API_KEY 优先，其次 ~/.config/manicode/credentials.json
public func readCodebuffAuth(_ home: String, _ env: [String: String]) -> CodebuffAuth? {
    let envToken = env["CODEBUFF_API_KEY"]
    let baseUrl = (env["CODEBUFF_API_URL"]?.trimmingCharacters(in: .whitespaces).emptyToNil()
        ?? "https://www.codebuff.com").replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
    if let envToken, !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return CodebuffAuth(token: envToken.trimmingCharacters(in: .whitespaces), baseUrl: baseUrl)
    }
    guard let parsed = parseJSONFile((home as NSString).appendingPathComponent(".config/manicode/credentials.json")) else {
        return nil
    }
    let token = quotaStr(parsed["authToken"]) ?? quotaStr(parsed["default"]?["authToken"])
    return token.map { CodebuffAuth(token: $0, baseUrl: baseUrl) }
}

public func fetchCodebuffAccount(_ auth: CodebuffAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "Bearer \(auth.token)",
        "accept": "application/json",
        "content-type": "application/json",
    ]
    do {
        let usage = try await quotaFetchJson(doFetch, "\(auth.baseUrl)/api/v1/usage", method: "POST",
                                             headers: headers,
                                             body: "{\"fingerprintId\":\"wattson-usage\"}")
        let u = usage.body
        let used = quotaNum(u["usage"]) ?? quotaNum(u["used"])
        let total = quotaNum(u["quota"]) ?? quotaNum(u["limit"])
        let remaining = quotaNum(u["remainingBalance"]) ?? quotaNum(u["remaining"])
        let nextQuotaReset = toEpochMs(u["next_quota_reset"])

        var windows: [QuotaWindow] = []
        if used != nil || total != nil || remaining != nil {
            let effectiveUsed: Double?
            if let used {
                effectiveUsed = used
            } else if let total, let remaining {
                effectiveUsed = total - remaining
            } else {
                effectiveUsed = nil
            }
            windows.append(QuotaWindow(
                key: "credits", label: "积分额度",
                total: total, used: used, remaining: remaining,
                percentage: percentOf(effectiveUsed, total),
                nextResetAt: nextQuotaReset))
        }

        // 订阅与周窗口是可选增强（原生实现给 2s grace），失败不拖垮主快照
        var planName: String?
        do {
            let sub = try await quotaFetchJson(doFetch, "\(auth.baseUrl)/api/user/subscription",
                                               headers: headers, timeoutMs: 5_000)
            let s = sub.body
            let subscription = s["subscription"]
            let rateLimit = s["rateLimit"]
            planName = quotaStr(subscription?["displayName"]) ?? quotaStr(s["displayName"])
                ?? quotaStr(subscription?["tier"]) ?? quotaStr(s["tier"])
            let weeklyUsed = quotaNum(rateLimit?["weeklyUsed"]) ?? quotaNum(rateLimit?["used"])
            let weeklyLimit = quotaNum(rateLimit?["weeklyLimit"]) ?? quotaNum(rateLimit?["limit"])
            if weeklyUsed != nil || weeklyLimit != nil {
                windows.append(QuotaWindow(
                    key: "week", label: "周额度",
                    total: weeklyLimit, used: weeklyUsed, remaining: nil,
                    percentage: percentOf(weeklyUsed, weeklyLimit),
                    nextResetAt: toEpochMs(rateLimit?["weeklyResetsAt"])))
            }
        } catch {
            // 订阅端点不可得时仅展示积分窗口
        }

        return finalizeAccount(kind: .codebuff, label: "Codebuff",
                               planName: planName, windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .codebuff, label: "Codebuff",
                               error: errText(error),
                               httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func codebuffAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readCodebuffAuth(home, env) else { return missingAccount(.codebuff, "Codebuff", now) }
    return await fetchCodebuffAccount(auth, doFetch, now)
}
