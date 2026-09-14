// Quotas/Codex.swift — OpenAI Codex 订阅额度：GET https://chatgpt.com/backend-api/wham/usage，
// 头 Authorization: Bearer + ChatGPT-Account-Id；primary_window=5 小时、secondary=周。
// chatgpt.com 受限网络不可达：由宿主进程配好代理出网（见 Quotas/Proxy.swift）。
import Foundation

public struct CodexAuth: Sendable, Equatable {
    public var token: String
    public var accountId: String?
    public init(token: String, accountId: String?) {
        self.token = token
        self.accountId = accountId
    }
}

/// 从 JWT payload 里取 ChatGPT 账户 ID（auth.json 缺 account_id 时的兜底）
public func extractCodexAccountId(_ token: String) -> String? {
    guard let payload = jwtPayload(token) else { return nil }
    return quotaStr(payload["https://api.openai.com/auth"]?["chatgpt_account_id"])
        ?? quotaStr(payload["chatgpt_account_id"])
}

/// 凭据：env CODEX_ACCESS_TOKEN(/CODEX_ACCOUNT_ID) 优先，其次 ~/.codex/auth.json
public func readCodexAuth(_ home: String, _ env: [String: String]) -> CodexAuth? {
    if let envToken = env["CODEX_ACCESS_TOKEN"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return CodexAuth(token: envToken.trimmingCharacters(in: .whitespaces),
                         accountId: env["CODEX_ACCOUNT_ID"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() })
    }
    guard let parsed = parseJSONFile((home as NSString).appendingPathComponent(".codex/auth.json")) else { return nil }
    guard let token = quotaStr(parsed["tokens"]?["access_token"]) else { return nil }
    let accountId = quotaStr(parsed["tokens"]?["account_id"]) ?? extractCodexAccountId(token)
    return CodexAuth(token: token, accountId: accountId)
}

extension String {
    func emptyToNil() -> String? { isEmpty ? nil : self }
}

func codexWindow(key: String, label: String, raw: JSON?, now: Double) -> QuotaWindow? {
    guard let w = raw?.obj else { return nil }
    let usedPercent = toPercent(quotaNum(w["used_percent"]) ?? quotaNum(w["utilization"]))
    var resetAt = toEpochMs(w["reset_at"])
    if resetAt == nil {
        if let after = quotaNum(w["reset_after_seconds"]), after >= 0 {
            resetAt = now + after * 1000
        }
    }
    if usedPercent == nil && resetAt == nil { return nil }
    return QuotaWindow(key: key, label: label, usedPercent: usedPercent,
                       percentage: usedPercent, nextResetAt: resetAt)
}

public func fetchCodexAccount(_ auth: CodexAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    var headers: [String: String] = [
        "authorization": "Bearer \(auth.token)",
        "accept": "application/json",
        "user-agent": "codex_cli_rs",
    ]
    if let accountId = auth.accountId { headers["chatgpt-account-id"] = accountId }
    do {
        let result = try await quotaFetchJson(doFetch, "https://chatgpt.com/backend-api/wham/usage", headers: headers)
        let root = result.body
        let rateLimit = root["rate_limit"]
        var windows: [QuotaWindow] = []
        if let primary = codexWindow(key: "fiveHour", label: "5 小时窗口", raw: rateLimit?["primary_window"], now: now) {
            windows.append(primary)
        }
        if let secondary = codexWindow(key: "week", label: "周额度", raw: rateLimit?["secondary_window"], now: now) {
            windows.append(secondary)
        }
        // 重置卡（rate_limit_reset_credits）：available_count=持有张数，
        // applicable_available_count=当前额度状态下可用的张数；字段缺失视为无此概念
        let resetCredits = root["rate_limit_reset_credits"]
        return finalizeAccount(
            kind: .codex, label: "Codex (ChatGPT)",
            planName: quotaStr(root["plan_type"]),
            windows: windows, anySuccess: true, now: now,
            resetCredits: resetCredits.flatMap { quotaNum($0["available_count"]) },
            applicableResetCredits: resetCredits.flatMap { quotaNum($0["applicable_available_count"]) })
    } catch {
        return finalizeAccount(kind: .codex, label: "Codex (ChatGPT)",
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func codexAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readCodexAuth(home, env) else { return missingAccount(.codex, "Codex (ChatGPT)", now) }
    return await fetchCodexAccount(auth, doFetch, now)
}
