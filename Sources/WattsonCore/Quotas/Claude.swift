// Quotas/Claude.swift — Claude Code 订阅额度：GET https://api.anthropic.com/api/oauth/usage，
// 头 Authorization: Bearer + anthropic-beta: oauth-2025-04-20（Claude Code OAuth 口径）。
// 响应窗口：five_hour / seven_day / seven_day_sonnet / extra_usage，utilization 兼容 0-1 与 0-100。
import Foundation

public struct ClaudeAuth: Sendable, Equatable {
    public var token: String
    public init(token: String) { self.token = token }
}

/// 凭据：env CLAUDE_ACCESS_TOKEN 优先，其次 ~/.claude/.credentials.json 的 claudeAiOauth
public func readClaudeAuth(_ home: String, _ env: [String: String]) -> ClaudeAuth? {
    if let envToken = env["CLAUDE_ACCESS_TOKEN"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return ClaudeAuth(token: envToken.trimmingCharacters(in: .whitespaces))
    }
    guard let parsed = parseJSONFile((home as NSString).appendingPathComponent(".claude/.credentials.json")) else { return nil }
    let token = quotaStr(parsed["claudeAiOauth"]?["accessToken"]) ?? quotaStr(parsed["accessToken"])
    return token.map { ClaudeAuth(token: $0) }
}

func claudeWindow(key: String, label: String, raw: JSON?) -> QuotaWindow? {
    guard let w = raw?.obj else { return nil }
    let usedPercent = toPercent(
        quotaNum(w["utilization"]) ?? quotaNum(w["used_percent"]) ?? quotaNum(w["percentage"]))
    let resetAt = toEpochMs(w["resets_at"] ?? w["reset_at"] ?? w["reset_after_seconds"])
    if usedPercent == nil && resetAt == nil { return nil }
    return QuotaWindow(key: key, label: label, usedPercent: usedPercent,
                       percentage: usedPercent, nextResetAt: resetAt)
}

public func fetchClaudeAccount(_ auth: ClaudeAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "Bearer \(auth.token)",
        "anthropic-beta": "oauth-2025-04-20",
        "accept": "application/json",
        "user-agent": "claude-cli",
    ]
    do {
        let result = try await quotaFetchJson(doFetch, "https://api.anthropic.com/api/oauth/usage", headers: headers)
        let root = result.body
        var windows: [QuotaWindow] = []
        let spec: [(String, String, String)] = [
            ("fiveHour", "5 小时窗口", "five_hour"),
            ("week", "周额度", "seven_day"),
            ("weekSonnet", "周额度（Sonnet）", "seven_day_sonnet"),
            ("extra", "额外用量", "extra_usage"),
        ]
        for (key, label, field) in spec {
            if let w = claudeWindow(key: key, label: label, raw: root[field]) {
                windows.append(w)
            }
        }
        return finalizeAccount(kind: .claude, label: "Claude Code",
                               planName: quotaStr(root["plan_type"]),
                               windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .claude, label: "Claude Code",
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func claudeAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readClaudeAuth(home, env) else { return missingAccount(.claude, "Claude Code", now) }
    return await fetchClaudeAccount(auth, doFetch, now)
}
