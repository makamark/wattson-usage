// Quotas/Copilot.swift — GitHub Copilot 订阅额度（移植自原生实现 CopilotUsageFetcher）：
// 凭据 = env COPILOT_API_TOKEN（GitHub OAuth token；设备流授权不在服务端做）；
// GET https://api.github.com/copilot_internal/user，头 Authorization: token + Copilot 伪装头；
// quota_snapshots.premium_interactions / chat → usedPercent = 100 - percent_remaining。
import Foundation

private let LABEL = "Copilot"

/// quota_snapshots 子窗口：unlimited / 占位（entitlement==0 && remaining==0）丢弃
func copilotWindow(key: String, label: String, raw: JSON?) -> QuotaWindow? {
    guard let s = raw?.obj else { return nil }
    if s["unlimited"]?.bool == true { return nil }
    let entitlement = quotaNum(s["entitlement"])
    let remaining = quotaNum(s["remaining"])
    if entitlement == 0 && remaining == 0 { return nil }
    guard let percentRemaining = toPercent(quotaNum(s["percent_remaining"])) else { return nil }
    let usedPercent = 100 - percentRemaining
    let used: Double?
    if let e = entitlement, let r = remaining { used = e - r } else { used = nil }
    return QuotaWindow(key: key, label: label, usedPercent: usedPercent,
                       total: entitlement, used: used, remaining: remaining,
                       percentage: usedPercent, nextResetAt: nil)
}

/// 凭据：env COPILOT_API_TOKEN
public func readCopilotAuth(_ env: [String: String]) -> String? {
    guard let token = env["COPILOT_API_TOKEN"] else { return nil }
    let t = token.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
}

public func fetchCopilotAccount(_ token: String, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "token \(token)",
        "accept": "application/json",
        "editor-version": "vscode/1.96.2",
        "editor-plugin-version": "copilot-chat/0.26.7",
        "user-agent": "GitHubCopilotChat/0.26.7",
        "x-github-api-version": "2025-04-01",
    ]
    do {
        let result = try await quotaFetchJson(doFetch, "https://api.github.com/copilot_internal/user", headers: headers)
        let root = result.body
        let snapshots = root["quota_snapshots"]
        let resetAt = toEpochMs(root["quota_reset_date"])
        var windows: [QuotaWindow] = []
        if var premium = copilotWindow(key: "premium", label: "Premium 请求", raw: snapshots?["premium_interactions"]) {
            premium.nextResetAt = resetAt
            windows.append(premium)
        }
        if var chat = copilotWindow(key: "chat", label: "Chat", raw: snapshots?["chat"]) {
            chat.nextResetAt = resetAt
            windows.append(chat)
        }
        return finalizeAccount(kind: .copilot, label: LABEL,
                               planName: quotaStr(root["copilot_plan"]),
                               windows: windows, anySuccess: snapshots?.isNull == false, now: now)
    } catch {
        return finalizeAccount(kind: .copilot, label: LABEL,
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func copilotAccount(_ home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    // home 未用：Copilot 凭据只来自 env，仅为统一签名保留
    guard let token = readCopilotAuth(env) else { return missingAccount(.copilot, LABEL, now) }
    return await fetchCopilotAccount(token, doFetch, now)
}
