// Quotas/Grok.swift — Grok CLI 订阅额度：凭据 = env GROK_OAUTH_TOKEN 或 ~/.grok/auth.json
// （scope 键控映射，优先 SuperGrok OIDC）；GET https://cli-chat-proxy.grok.com/v1/billing?format=credits，
// 头 Bearer + x-xai-token-auth: xai-grok-cli；config.creditUsagePercent = 已用百分比。
import Foundation

public struct GrokAuth: Sendable, Equatable {
    public var token: String
    public var expired: Bool
    public init(token: String, expired: Bool) {
        self.token = token
        self.expired = expired
    }
}

/// SuperGrok / SuperGrok Heavy 档位名归一（原生实现口径）
public func grokPlanName(level: String?) -> String? {
    let trimmed = level?.trimmingCharacters(in: .whitespaces) ?? ""
    if trimmed.isEmpty { return nil }
    let compact = String(trimmed.lowercased().filter { $0 >= "a" && $0 <= "z" })
    if compact == "supergrokheavy" || compact == "heavy" { return "SuperGrok Heavy" }
    if compact == "supergrok" { return "SuperGrok" }
    return trimmed
}

private let oidcScopePrefix = "https://auth.x.ai::"
private let legacySessionScope = "https://accounts.x.ai/sign-in"

/// 纯文本错误（无 HTTP 状态码）
private struct GrokError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 凭据：env GROK_OAUTH_TOKEN 优先；其次 ~/.grok/auth.json（GROK_HOME 可覆盖）。
/// auth.json 是 scope → entry 映射，只接受带非空 key 的条目；优先 OIDC，回退 legacy session。
public func readGrokAuth(_ home: String, _ env: [String: String], now: Double = Date.nowMs()) -> GrokAuth? {
    if let envToken = env["GROK_OAUTH_TOKEN"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return GrokAuth(token: envToken.trimmingCharacters(in: .whitespaces), expired: false)
    }
    let grokHome = env["GROK_HOME"].flatMap { $0.trimmingCharacters(in: .whitespaces).emptyToNil() }
        ?? (home as NSString).appendingPathComponent(".grok")
    guard let raw = readTextFile((grokHome as NSString).appendingPathComponent("auth.json")),
          let parsed = try? JSON.parse(raw), let dict = parsed.obj else { return nil }
    var oidc: (token: String, expiresAt: Double?)?
    var legacy: (token: String, expiresAt: Double?)?
    // Swift Dictionary 无序：按键排序遍历保证确定性；语义仍是 OIDC 优先（后者覆盖）、legacy 取第一个
    for scope in dict.keys.sorted() {
        guard let entry = dict[scope]?.obj, let token = quotaStr(entry["key"]) else { continue }
        let candidate = (token: token, expiresAt: toEpochMs(entry["expires_at"]))
        if scope.hasPrefix(oidcScopePrefix) {
            oidc = candidate
        } else if scope == legacySessionScope || scope.contains("/sign-in") {
            if legacy == nil { legacy = candidate }
        }
    }
    guard let picked = oidc ?? legacy else { return nil }
    let expired = picked.expiresAt.map { $0 <= now } ?? false
    return GrokAuth(token: picked.token, expired: expired)
}

public func fetchGrokAccount(_ auth: GrokAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "Bearer \(auth.token)",
        "x-xai-token-auth": "xai-grok-cli",
        "accept": "application/json",
        "user-agent": "wattson-usage",
    ]
    do {
        let result = try await quotaFetchJson(
            doFetch, "https://cli-chat-proxy.grok.com/v1/billing?format=credits", headers: headers)
        let root = result.body
        guard let config = root["config"], !config.isNull else {
            throw GrokError(message: "响应缺少 config 字段")
        }
        // currentPeriod.end 缺失/null 时回退 billingPeriodEnd（TS ?? 口径）
        let periodEnd = config["currentPeriod"]?["end"] ?? .null
        let resetAt = toEpochMs(periodEnd.isNull ? config["billingPeriodEnd"] : periodEnd)
        // 优先 creditUsagePercent；否则 onDemandCap/onDemandUsed（{val: number}）推导
        let usedPercent = toPercent(quotaNum(config["creditUsagePercent"]))
            ?? percentOf(quotaNum(config["onDemandUsed"]?["val"]),
                         quotaNum(config["onDemandCap"]?["val"]))
        var windows: [QuotaWindow] = []
        if usedPercent != nil || resetAt != nil {
            windows.append(QuotaWindow(key: "cycle", label: "订阅额度",
                                       usedPercent: usedPercent, percentage: usedPercent, nextResetAt: resetAt))
        }
        return finalizeAccount(
            kind: .grok, label: "Grok",
            planName: grokPlanName(level: quotaStr(config["subscriptionTier"]) ?? quotaStr(root["subscriptionTier"])),
            windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .grok, label: "Grok",
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func grokAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readGrokAuth(home, env, now: now) else { return missingAccount(.grok, "Grok", now) }
    if auth.expired {
        return QuotaAccount(kind: .grok, label: "Grok", available: false, unavailableReason: "error",
                            error: "凭据已过期，请重新 grok login", planName: nil, windows: [],
                            fetchedAt: now, lastSuccessAt: nil)
    }
    return await fetchGrokAccount(auth, doFetch, now)
}
