// Quotas/Factory.swift — Factory 订阅额度（移植自原生实现 FactoryStatusProbe 的 API-key 口径）：
// 凭据 = env FACTORY_API_KEY 或 ~/.factory/.env 的 FACTORY_API_KEY= 行；
// GET https://api.factory.ai/api/billing/limits（失败回退 app.factory.ai）；
// limits.standard.{fiveHour,weekly,monthly} = 5h/周/月三窗口（纯百分比 + windowEnd/secondsRemaining）。
import Foundation

/// 凭据：env FACTORY_API_KEY 优先，其次 ~/.factory/.env 的 FACTORY_API_KEY= 行
public func readFactoryApiKey(_ home: String, _ env: [String: String]) -> String? {
    if let envKey = env["FACTORY_API_KEY"] {
        let t = envKey.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
    }
    guard
        let contents = readTextFile((home as NSString).appendingPathComponent(".factory/.env"))
    else { return nil }
    for rawLine in contents.components(separatedBy: .newlines) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.hasPrefix("export ") {
            line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
        }
        guard let eq = line.firstIndex(of: "=") else { continue }
        if line[..<eq].trimmingCharacters(in: .whitespaces) != "FACTORY_API_KEY" { continue }
        var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
        // 引号剥离（TS replace(/^["']|["']$/g, '')：独立剥掉一个首引号与一个尾引号）
        if let first = value.first, first == "\"" || first == "'" { value.removeFirst() }
        if let last = value.last, last == "\"" || last == "'" { value.removeLast() }
        if !value.isEmpty { return value }
    }
    return nil
}

/// 单窗口：usedPercent 直接给；windowEnd 兼容 epoch 秒/毫秒/ISO；过期窗口视为已重置（0%）
func factoryWindow(key: String, label: String, raw: JSON?, now: Double) -> QuotaWindow? {
    guard let w = raw?.obj else { return nil }
    let secondsRemaining = quotaNum(w["secondsRemaining"])
    var resetAt: Double?
    if let sr = secondsRemaining, sr > 0 { resetAt = now + sr * 1000 }
    let windowEnd = toEpochMs(w["windowEnd"])
    if resetAt == nil, let we = windowEnd, we > now { resetAt = we }
    let expired = resetAt == nil && windowEnd != nil
    let usedPercent = expired ? 0 : toPercent(quotaNum(w["usedPercent"]))
    guard let usedPercent else { return nil }
    let clamped = min(100, max(0, usedPercent))
    return QuotaWindow(key: key, label: label,
                       usedPercent: clamped, percentage: clamped, nextResetAt: resetAt)
}

public func fetchFactoryAccount(_ apiKey: String, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "Bearer \(apiKey)",
        "accept": "application/json",
        "x-factory-client": "wattson-usage",
    ]
    var body: JSON?
    var lastErr: Error?
    var httpStatus: Double?
    for base in ["https://api.factory.ai", "https://app.factory.ai"] {
        do {
            body = try await quotaFetchJson(doFetch, "\(base)/api/billing/limits", headers: headers).body
            lastErr = nil
            break
        } catch {
            lastErr = error
            httpStatus = readHttpStatus(error).map(Double.init)
        }
    }
    if lastErr != nil || body == nil {
        return finalizeAccount(kind: .factory, label: "Factory",
                               error: lastErr.map(errText), httpStatus: httpStatus, now: now)
    }
    let root = body ?? .null
    let standard = root["limits"]?["standard"]
    var windows: [QuotaWindow] = []
    if let w = factoryWindow(key: "fiveHour", label: "5 小时窗口", raw: standard?["fiveHour"], now: now) {
        windows.append(w)
    }
    if let w = factoryWindow(key: "week", label: "周额度", raw: standard?["weekly"], now: now) {
        windows.append(w)
    }
    if let w = factoryWindow(key: "cycle", label: "月度额度", raw: standard?["monthly"], now: now) {
        windows.append(w)
    }
    return finalizeAccount(kind: .factory, label: "Factory",
                           windows: windows, anySuccess: standard?.isNull == false, now: now)
}

public func factoryAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let apiKey = readFactoryApiKey(home, env) else { return missingAccount(.factory, "Factory", now) }
    return await fetchFactoryAccount(apiKey, doFetch, now)
}
