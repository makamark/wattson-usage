// Quotas/Kiro.swift — Kiro (AWS CodeWhisperer) 用量限额（移植自原生实现 KiroUsageLimitsAPI）：
// 凭据 = env KIRO_ACCESS_TOKEN+KIRO_PROFILE_ARN，或 kiro-cli 本地 SQLite（只读，经系统 sqlite3 CLI）：
//   macOS ~/Library/Application Support/kiro-cli/data.sqlite3，Linux $XDG_DATA_HOME|~/.local/share /kiro-cli/data.sqlite3
//   auth_kv['kirocli:odic:token'].access_token + state['api.codewhisperer.profile'].arn；
// POST {codewhisperer|q}.amazonaws.com/，头 X-Amz-Target: GetUsageLimits，body {profileArn}。
import Foundation

public struct KiroAuth: Sendable, Equatable {
    public var accessToken: String
    public var profileArn: String
    public init(accessToken: String, profileArn: String) {
        self.accessToken = accessToken
        self.profileArn = profileArn
    }
}

private let LABEL = "Kiro"

private let REGION_ENDPOINTS: [String: String] = [
    "us-east-1": "https://codewhisperer.us-east-1.amazonaws.com/",
    "eu-central-1": "https://q.eu-central-1.amazonaws.com/",
]

public func kiroStateDatabasePath(_ home: String, _ env: [String: String],
                                  platform: String = currentPlatform()) -> String? {
    if let override = env["KIRO_DATA_DIR"]?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
        return (override as NSString).appendingPathComponent("data.sqlite3")
    }
    if platform == "darwin" {
        return (home as NSString).appendingPathComponent("Library/Application Support/kiro-cli/data.sqlite3")
    }
    let dataHome = env["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespaces).emptyToNil()
        ?? (home as NSString).appendingPathComponent(".local/share")
    return (dataHome as NSString).appendingPathComponent("kiro-cli/data.sqlite3")
}

/// 取单行单列 value 并按 JSON 解析（sqlite3 -json 输出 [{value: "..."}]）
func querySqliteValue(_ run: RunLike, _ dbPath: String, _ sql: String) async throws -> JSON? {
    guard fileExists(dbPath) else { return nil }
    let result = try await run("sqlite3", ["-json", dbPath, sql])
    let rows = try JSON.parse(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    guard let raw = rows[0]?["value"]?.str,
          !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return try? JSON.parse(raw)
}

/// 凭据：env KIRO_ACCESS_TOKEN+KIRO_PROFILE_ARN 优先，其次 kiro-cli 本地 SQLite（只读探测）
public func readKiroAuth(_ home: String, _ env: [String: String],
                         run: RunLike = { try await runProcess($0, $1) }) async -> KiroAuth? {
    let envToken = env["KIRO_ACCESS_TOKEN"]?.trimmingCharacters(in: .whitespaces)
    let envArn = env["KIRO_PROFILE_ARN"]?.trimmingCharacters(in: .whitespaces)
    if let envToken, !envToken.isEmpty, let envArn, !envArn.isEmpty {
        return KiroAuth(accessToken: envToken, profileArn: envArn)
    }
    guard let dbPath = kiroStateDatabasePath(home, env) else { return nil }
    do {
        let tokenJson = try await querySqliteValue(
            run, dbPath, "SELECT value FROM auth_kv WHERE key = 'kirocli:odic:token'")
        let accessToken = tokenJson?["access_token"]?.str
        let profileJson = try await querySqliteValue(
            run, dbPath, "SELECT value FROM state WHERE key = 'api.codewhisperer.profile'")
        let profileArn = profileJson?["arn"]?.str
        if let accessToken, !accessToken.isEmpty, let profileArn, !profileArn.isEmpty {
            return KiroAuth(accessToken: accessToken, profileArn: profileArn)
        }
    } catch {
        // sqlite3 缺失或库损坏 → 视为无凭据
    }
    return nil
}

/// arn:aws:codewhisperer:<region>:...:profile/<name> → 端点；不支持的区域返回 nil
public func kiroEndpointForArn(_ profileArn: String) -> String? {
    let parts = profileArn.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 6, parts[0] == "arn", parts[1] == "aws", parts[2] == "codewhisperer" else { return nil }
    let name = parts[5]
    guard name.hasPrefix("profile/"), name.count > "profile/".count else { return nil }
    return REGION_ENDPOINTS[parts[3]]
}

public func fetchKiroAccount(_ auth: KiroAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    guard let endpoint = kiroEndpointForArn(auth.profileArn) else {
        return finalizeAccount(kind: .kiro, label: LABEL,
                               error: "unsupported profile ARN: \(auth.profileArn)",
                               httpStatus: nil, now: now)
    }
    let headers = [
        "content-type": "application/x-amz-json-1.0",
        "x-amz-target": "AmazonCodeWhispererService.GetUsageLimits",
        "authorization": "Bearer \(auth.accessToken)",
    ]
    do {
        let result = try await quotaFetchJson(doFetch, endpoint, method: "POST", headers: headers,
                                              body: "{\"profileArn\":\"\(auth.profileArn)\"}")
        let root = result.body
        let breakdown = root["usageBreakdownList"]?.arr ?? []
        let credit = breakdown.first { $0["resourceType"]?.str == "CREDIT" }
        guard let credit else { throw QuotaMessageError(message: "响应未报告 CREDIT 用量") }
        let total = quotaNum(credit["usageLimitWithPrecision"])
        let totalUsed = quotaNum(credit["currentUsageWithPrecision"])
        let overageUsed = quotaNum(credit["currentOveragesWithPrecision"]) ?? 0
        guard let total, let totalUsed else { throw QuotaMessageError(message: "CREDIT 条目缺少 limit/usage") }
        // currentUsage 含 overage；planUsed 才对应订阅口径
        let planUsed = max(0, totalUsed - max(0, overageUsed))
        let resetRaw = quotaNum(credit["nextDateReset"]) ?? quotaNum(root["nextDateReset"])
        // 合理的 Unix 秒区间（2001-2100）；毫秒或其它单位不可信
        let resetAt = resetRaw.flatMap { ($0 >= 1e9 && $0 <= 4_102_444_800) ? $0 * 1000 : nil }
        let windows = [QuotaWindow(
            key: "cycle", label: "周期额度",
            total: total, used: planUsed, remaining: max(0, total - planUsed),
            percentage: percentOf(planUsed, total),
            nextResetAt: resetAt)]
        return finalizeAccount(kind: .kiro, label: LABEL, windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .kiro, label: LABEL,
                               error: errText(error),
                               httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func kiroAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = await readKiroAuth(home, env) else { return missingAccount(.kiro, LABEL, now) }
    return await fetchKiroAccount(auth, doFetch, now)
}
