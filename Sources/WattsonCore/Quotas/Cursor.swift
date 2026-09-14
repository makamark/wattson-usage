// Quotas/Cursor.swift — Cursor 订阅额度（参考 cockpit-tools cursor_account.rs）：
// GET https://cursor.com/api/usage-summary，认证走 Cookie
// `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>`（userId 取自 accessToken JWT 的 sub）。
import Foundation

public struct CursorAuth: Sendable, Equatable {
    public var token: String
    public init(token: String) { self.token = token }
}

/// 从 JWT payload 取 WorkOS 用户 id（sub / user_id / userId）
public func extractCursorUserId(token: String) -> String? {
    guard let payload = jwtPayload(token) else { return nil }
    return quotaStr(payload["sub"]) ?? quotaStr(payload["user_id"]) ?? quotaStr(payload["userId"])
}

/// 凭据：env CURSOR_ACCESS_TOKEN 优先；其次 ~/.cursor/auth.json | credentials.json 的 accessToken
public func readCursorAuth(_ home: String, _ env: [String: String]) -> CursorAuth? {
    if let envToken = env["CURSOR_ACCESS_TOKEN"], !envToken.trimmingCharacters(in: .whitespaces).isEmpty {
        return CursorAuth(token: envToken.trimmingCharacters(in: .whitespaces))
    }
    for name in ["auth.json", "credentials.json"] {
        guard let parsed = parseJSONFile((home as NSString).appendingPathComponent(".cursor/\(name)")) else { continue }
        let token = quotaStr(parsed["accessToken"]) ?? quotaStr(parsed["access_token"])
            ?? quotaStr(parsed["cursorAuth"]?["accessToken"])
        if let token { return CursorAuth(token: token) }
    }
    return nil
}

/// usage-summary 响应是演进中的结构：优先 prompts.secondary/primary，兼容 quotaDisplay[]
func cursorWindow(key: String, label: String, raw: JSON?) -> QuotaWindow? {
    guard let w = raw?.obj else { return nil }
    let usedPercent = toPercent(
        quotaNum(w["usedPercentage"]) ?? quotaNum(w["used_percent"]) ?? quotaNum(w["utilization"]))
    let resetAt = toEpochMs(w["resetDate"] ?? w["reset_date"] ?? w["nextResetTime"])
    if usedPercent == nil && resetAt == nil { return nil }
    return QuotaWindow(key: key, label: label, usedPercent: usedPercent,
                       percentage: usedPercent, nextResetAt: resetAt)
}

func cursorWindows(root: JSON) -> [QuotaWindow] {
    var windows: [QuotaWindow] = []
    let prompts = root["prompts"] ?? JSON.obj([:])
    if let primary = cursorWindow(key: "fiveHour", label: "5 小时窗口",
                                  raw: prompts["primary"] ?? prompts["primary_window"]) {
        windows.append(primary)
    }
    if let secondary = cursorWindow(key: "cycle", label: "周期额度",
                                    raw: prompts["secondary"] ?? prompts["secondary_window"]) {
        windows.append(secondary)
    }
    if windows.isEmpty, let display = root["quotaDisplay"]?.arr {
        for item in display {
            let label = quotaStr(item["name"]) ?? "额度窗口"
            if let w = cursorWindow(key: item["name"]?.str ?? "cycle", label: label, raw: item) {
                windows.append(w)
            }
        }
    }
    return windows
}

public func fetchCursorAccount(_ auth: CursorAuth, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    guard let userId = extractCursorUserId(token: auth.token) else {
        return finalizeAccount(kind: .cursor, label: "Cursor",
                               error: "accessToken 不是合法 JWT（缺少 WorkOS 用户 id）", now: now)
    }
    let headers = [
        "accept": "application/json",
        "cookie": "WorkosCursorSessionToken=\(userId)%3A%3A\(auth.token)",
        "user-agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
    ]
    do {
        let result = try await quotaFetchJson(doFetch, "https://cursor.com/api/usage-summary", headers: headers)
        let root = result.body
        let windows = cursorWindows(root: root)
        return finalizeAccount(kind: .cursor, label: "Cursor",
                               planName: quotaStr(root["membershipType"]),
                               windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .cursor, label: "Cursor",
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func cursorAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let auth = readCursorAuth(home, env) else { return missingAccount(.cursor, "Cursor", now) }
    return await fetchCursorAccount(auth, doFetch, now)
}
