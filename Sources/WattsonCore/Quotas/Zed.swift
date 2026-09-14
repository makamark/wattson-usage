// Quotas/Zed.swift — Zed 订阅额度（移植自原生实现 ZedStatusProbe）：
// 凭据 = env ZED_ACCESS_TOKEN+ZED_USER_ID（或显式 ZED_KEYCHAIN=1 后读 macOS 钥匙串
// server/service = https://zed.dev，account = userID，password = access token）；
// GET https://cloud.zed.dev/client/users/me，注意 Authorization 头是 "<userID> <accessToken>" 而非 Bearer。
import Foundation

/// TS `new Error(msg)` 的对应物：只带文案、无 HTTP 状态（finalizeAccount 归因为 error）
struct QuotaMessageError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

public struct ZedAuth: Sendable, Equatable {
    public var userId: String
    public var token: String
    public init(userId: String, token: String) {
        self.userId = userId
        self.token = token
    }
}

private let LABEL = "Zed"
private let KEYCHAIN_SERVICE = "https://zed.dev"

/// 从 security 输出里抽 "acct"<blob>="123" 形式的属性
func extractAcct(_ output: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: "\"acct\"<blob>=\"([^\"]+)\"") else { return nil }
    let ns = output as NSString
    guard let m = re.firstMatch(in: output, options: [], range: NSRange(location: 0, length: ns.length)),
          m.range(at: 1).location != NSNotFound else { return nil }
    let t = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
    return t.isEmpty ? nil : t
}

func keychainCredentials(_ run: RunLike) async -> ZedAuth? {
    // 原生实现顺序：先 internet password，再 generic password
    for kind in ["find-internet-password", "find-generic-password"] {
        do {
            let attrs = try await run("/usr/bin/security", [kind, "-s", KEYCHAIN_SERVICE])
            let userId = extractAcct(attrs.stdout + attrs.stderr)
            let password = try await run("/usr/bin/security", [kind, "-s", KEYCHAIN_SERVICE, "-w"])
            let token = password.stdout.trimmingCharacters(in: .whitespaces)
            if let userId, !token.isEmpty { return ZedAuth(userId: userId, token: token) }
        } catch {
            // 换下一种钥匙串条目
        }
    }
    return nil
}

/// 凭据：env ZED_ACCESS_TOKEN+ZED_USER_ID 优先；其次 macOS 钥匙串（须显式 ZED_KEYCHAIN=1
/// 开启——headless LaunchAgent 下主动读他应用钥匙串可能弹授权框，默认不碰）。
public func readZedAuth(_ env: [String: String], run: RunLike = { try await runProcess($0, $1) }) async -> ZedAuth? {
    let envToken = env["ZED_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespaces)
    let envUser = env["ZED_USER_ID"]?.trimmingCharacters(in: .whitespaces)
    if let envToken, !envToken.isEmpty, let envUser, !envUser.isEmpty {
        return ZedAuth(userId: envUser, token: envToken)
    }
    if env["ZED_KEYCHAIN"] != "1" { return nil }
    if currentPlatform() != "darwin" { return nil }
    return await keychainCredentials(run)
}

public func fetchZedAccount(_ auth: ZedAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        // Zed 协议："<userID> <accessToken>"，不是 Bearer
        "authorization": "\(auth.userId) \(auth.token)",
        "accept": "application/json",
    ]
    do {
        let result = try await quotaFetchJson(doFetch, "https://cloud.zed.dev/client/users/me", headers: headers)
        let root = result.body
        guard let plan = root["plan"], !plan.isNull else {
            throw QuotaMessageError(message: "响应缺少 plan 字段")
        }
        let editPredictions = plan["usage"]?["edit_predictions"].flatMap { $0.isNull ? nil : $0 }
        let period = plan["subscription_period"]

        var windows: [QuotaWindow] = []
        let limit = editPredictions.flatMap { quotaNum($0["limit"]) }
        let used = editPredictions.flatMap { quotaNum($0["used"]) }
        // limit 可能是字符串 "unlimited"（quotaNum → nil），此时不展示该窗口
        if let limit, let used {
            windows.append(QuotaWindow(
                key: "editPredictions", label: "Edit Predictions",
                total: limit, used: used, remaining: max(0, limit - used),
                percentage: percentOf(used, limit),
                nextResetAt: period.flatMap { toEpochMs($0["ended_at"]) }))
        }
        // 账期进度：按订阅周期已过时间折算
        let startedAt = period.flatMap { toEpochMs($0["started_at"]) }
        let endedAt = period.flatMap { toEpochMs($0["ended_at"]) }
        if let startedAt, let endedAt, endedAt > startedAt {
            let elapsed = min(100, max(0, (now - startedAt) / (endedAt - startedAt) * 100))
            windows.append(QuotaWindow(
                key: "cycle", label: "账期进度",
                usedPercent: elapsed, percentage: elapsed, nextResetAt: endedAt))
        }
        return finalizeAccount(kind: .zed, label: LABEL,
                               planName: quotaStr(plan["plan_v3"]),
                               windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .zed, label: LABEL,
                               error: errText(error),
                               httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func zedAccount(_ home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    // home 未用：Zed 凭据只来自 env 与 macOS 钥匙串，仅为统一签名保留
    guard let auth = await readZedAuth(env) else { return missingAccount(.zed, LABEL, now) }
    return await fetchZedAccount(auth, doFetch, now)
}
