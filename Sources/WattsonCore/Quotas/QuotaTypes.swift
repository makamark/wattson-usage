// Quotas/QuotaTypes.swift — 订阅额度多 provider 共享类型与工具。
// 统一窗口模型兼容两种口径：绝对值（glm/workbuddy 的 总额/已用/剩余）与
// 纯百分比（codex/claude/cursor 只给 used_percent/utilization）。
import Foundation

public enum QuotaKind: String, Sendable, CaseIterable, Codable {
    case glm, codex, claude, cursor, workbuddy, trae
    case kimi, gemini, grok, zed, kiro, codebuff, factory
    case copilot, openrouter, minimax
    case antigravity
}

public struct QuotaWindow: Sendable, Equatable, Hashable {
    /// fiveHour | week | cycle | sevenDaySonnet | extra | …
    public var key: String
    public var label: String
    /// 已用百分比（0-100）。纯百分比口径的 provider 只填这个
    public var usedPercent: Double?
    /// 绝对值口径（prompt/credit 数），缺失为 nil
    public var total: Double?
    public var used: Double?
    public var remaining: Double?
    /// 展示百分比 0-100：优先官方值，否则由 used/total 推导；都没有则取 usedPercent
    public var percentage: Double?
    public var nextResetAt: Double?

    public init(key: String, label: String, usedPercent: Double? = nil,
                total: Double? = nil, used: Double? = nil, remaining: Double? = nil,
                percentage: Double? = nil, nextResetAt: Double? = nil) {
        self.key = key
        self.label = label
        self.usedPercent = usedPercent
        self.total = total
        self.used = used
        self.remaining = remaining
        self.percentage = percentage
        self.nextResetAt = nextResetAt
    }
}

public struct QuotaAccount: Sendable, Equatable, Hashable {
    public var kind: QuotaKind
    public var label: String
    public var available: Bool
    /// no_credentials | loading | http_401 | http_error | no_plan | error | uninitialized
    public var unavailableReason: String?
    public var error: String?
    public var planName: String?
    public var windows: [QuotaWindow]
    /// 额度重置卡张数（codex rate_limit_reset_credits.available_count）；无此概念不设
    public var resetCredits: Double?
    /// 当前额度状态下可用的重置卡张数（applicable_available_count）；无此概念不设
    public var applicableResetCredits: Double?
    public var fetchedAt: Double
    public var lastSuccessAt: Double?

    public init(kind: QuotaKind, label: String, available: Bool, unavailableReason: String?,
                error: String?, planName: String?, windows: [QuotaWindow],
                resetCredits: Double? = nil, applicableResetCredits: Double? = nil,
                fetchedAt: Double, lastSuccessAt: Double?) {
        self.kind = kind
        self.label = label
        self.available = available
        self.unavailableReason = unavailableReason
        self.error = error
        self.planName = planName
        self.windows = windows
        self.resetCredits = resetCredits
        self.applicableResetCredits = applicableResetCredits
        self.fetchedAt = fetchedAt
        self.lastSuccessAt = lastSuccessAt
    }
}

public struct QuotaSnapshot: Sendable, Equatable {
    public var accounts: [QuotaAccount]
    public init(accounts: [QuotaAccount]) { self.accounts = accounts }
}

// MARK: - 动态取值（TS 侧 quotaNum/quotaStr 口径）

/// 数字或字符串数字 → Double；其余（含布尔、空串、非法串）→ nil
public func quotaNum(_ v: JSON?) -> Double? {
    guard let v else { return nil }
    if let n = v.num { return n }
    if let s = v.str, !s.trimmingCharacters(in: .whitespaces).isEmpty, let n = Double(s) {
        return n
    }
    return nil
}

public func quotaStr(_ v: JSON?) -> String? {
    guard let s = v?.str else { return nil }
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
}

/// utilization 兼容 0-1 与 0-100 两种口径，统一成 0-100
public func toPercent(_ v: Double?) -> Double? {
    guard let v else { return nil }
    return v > 0 && v <= 1 ? v * 100 : v
}

/// 由 used/total 推导百分比（0-100）
public func percentOf(_ used: Double?, _ total: Double?) -> Double? {
    guard let used, let total, total > 0 else { return nil }
    return min(100, max(0, used / total * 100))
}

// MARK: - 账号收尾

/// 各 provider 通用的 QuotaAccount 收尾：按成功数/HTTP 状态归一可用性
public func finalizeAccount(kind: QuotaKind, label: String, planName: String? = nil,
                            windows: [QuotaWindow] = [], error: String? = nil,
                            httpStatus: Double? = nil, anySuccess: Bool? = nil, now: Double,
                            resetCredits: Double? = nil, applicableResetCredits: Double? = nil
) -> QuotaAccount {
    let available = (anySuccess == true) && !windows.isEmpty
    var reason: String?
    if available {
        reason = nil
    } else if httpStatus == 401 || httpStatus == 403 {
        reason = "http_401"
    } else if httpStatus != nil {
        reason = "http_error"
    } else if anySuccess == true {
        reason = "no_plan"
    } else {
        reason = "error"
    }
    if !available && reason == nil { reason = "error" }
    return QuotaAccount(
        kind: kind, label: label, available: available, unavailableReason: reason,
        error: error, planName: planName, windows: windows,
        resetCredits: resetCredits, applicableResetCredits: applicableResetCredits,
        fetchedAt: now, lastSuccessAt: available ? now : nil)
}

/// 无凭据时的占位账号
public func missingAccount(_ kind: QuotaKind, _ label: String, _ now: Double) -> QuotaAccount {
    QuotaAccount(kind: kind, label: label, available: false, unavailableReason: "no_credentials",
                 error: nil, planName: nil, windows: [], fetchedAt: now, lastSuccessAt: nil)
}

/// 带超时的 GET/POST（超时由生产 fetch 的 URLRequest.timeoutInterval 承担；测试注入不触网）
public func quotaFetchJson(_ doFetch: FetchLike, _ url: String,
                           method: String = "GET", headers: [String: String] = [:],
                           body: String? = nil, timeoutMs: Double = 15_000) async throws -> (status: Int, body: JSON) {
    _ = timeoutMs // 语义保留：注入 fetch 用于测试时无真实超时面；生产 fetch 按请求设置
    let res = try await doFetch(FetchRequest(url: url, method: method, headers: headers, body: body))
    if res.status == 401 || res.status == 403 {
        throw HTTPStatusError(status: res.status, message: "HTTP \(res.status)（凭据无效或已过期）")
    }
    if !res.ok {
        throw HTTPStatusError(status: res.status, message: "HTTP \(res.status)")
    }
    return (res.status, res.body)
}
