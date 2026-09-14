// Quotas/MiniMax.swift — MiniMax 编码订阅额度（移植自原生实现 MiniMaxUsageFetcher 的 remains 口径）：
// 凭据 = env MINIMAX_CODING_API_KEY / MINIMAX_API_KEY；
// GET {apiBase}/v1/token_plan/remains → 回退 /v1/api/openplatform/coding_plan/remains，
// 国际（minimax.io）失败换中国（minimaxi.com）；*_usage_count 字段是剩余量而非已用量。
import Foundation

private let LABEL = "MiniMax"

public struct MiniMaxRegion: Sendable, Equatable {
    public let apiBase: String
    public init(apiBase: String) { self.apiBase = apiBase }
}

private let REGION_INTL = MiniMaxRegion(apiBase: "https://api.minimax.io")
private let REGION_CN = MiniMaxRegion(apiBase: "https://api.minimaxi.com")

/// 凭据：env MINIMAX_CODING_API_KEY → MINIMAX_API_KEY 回退；MINIMAX_REGION=cn 决定首选区域
public func readMiniMaxAuth(_ env: [String: String]) -> (token: String, regions: [MiniMaxRegion])? {
    let coding = env["MINIMAX_CODING_API_KEY"]?.trimmingCharacters(in: .whitespaces) ?? ""
    let generic = env["MINIMAX_API_KEY"]?.trimmingCharacters(in: .whitespaces) ?? ""
    // TS `?.trim() || ?.trim() || ''`：空串视为缺省，向后回退
    let token = !coding.isEmpty ? coding : generic
    if token.isEmpty { return nil }
    let primary = env["MINIMAX_REGION"]?.trimmingCharacters(in: .whitespaces).lowercased() == "cn"
        ? REGION_CN : REGION_INTL
    let other = primary == REGION_CN ? REGION_INTL : REGION_CN
    return (token, [primary, other])
}

/// 单条 model_remains → 窗口；intervals/weekly 的 usage_count 字段是剩余量
func minimaxWindowFromItem(key: String, label: String, item: [String: JSON],
                           totalKey: String, remainingKey: String,
                           remainingPercentKey: String, endKey: String) -> QuotaWindow? {
    let total = quotaNum(item[totalKey])
    let remainingRaw = quotaNum(item[remainingKey])
    let remainingPercent = quotaNum(item[remainingPercentKey])
    let used: Double?
    if let t = total, let r = remainingRaw { used = max(0, t - r) } else { used = nil }
    let percentage = percentOf(used, total)
        ?? remainingPercent.map { min(100, max(0, 100 - $0)) }
    if percentage == nil && total == nil { return nil }
    return QuotaWindow(key: key, label: label,
                       total: total, used: used, remaining: remainingRaw,
                       percentage: percentage, nextResetAt: toEpochMs(item[endKey]))
}

public func fetchMiniMaxAccount(_ auth: (token: String, regions: [MiniMaxRegion]), _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    let headers = [
        "authorization": "Bearer \(auth.token)",
        "accept": "application/json",
        "content-type": "application/json",
        "mm-api-source": "wattson-usage",
    ]
    var body: JSON?
    var lastErr: Error?
    var httpStatus: Double?
    // 双层回退：区域 × 两条 path，任一成功即停（外层 break 语义）
    outer: for region in auth.regions {
        for path in ["/v1/token_plan/remains", "/v1/api/openplatform/coding_plan/remains"] {
            do {
                body = try await quotaFetchJson(doFetch, "\(region.apiBase)\(path)", headers: headers).body
                lastErr = nil
                break outer
            } catch {
                lastErr = error
                httpStatus = readHttpStatus(error).map(Double.init)
            }
        }
    }
    if lastErr != nil || body == nil {
        return finalizeAccount(kind: .minimax, label: LABEL,
                               error: lastErr.map(errText), httpStatus: httpStatus, now: now)
    }
    do {
        let root = body ?? .null
        let data = root["data"] ?? .null
        let baseResp = data["base_resp"] ?? root["base_resp"]
        let statusCode = quotaNum(baseResp?["status_code"])
        if let statusCode, statusCode != 0 {
            let message = quotaStr(baseResp?["status_message"])
                ?? "status_code \(statusCode.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(statusCode)) : "\(statusCode)")"
            if statusCode == 1004 {
                throw HTTPStatusError(status: 401, message: message)
            }
            throw HTTPStatusError(status: 0, message: message)
        }
        let items = data["model_remains"]?.arr ?? []
        if items.isEmpty { throw QuotaMessageError(message: "响应缺少 model_remains 数据") }

        // 多模型 lane 取最吃紧的一个窗口口径
        var interval: QuotaWindow?
        var week: QuotaWindow?
        for raw in items {
            guard let obj = raw.obj else { continue }
            if let candidate = minimaxWindowFromItem(
                key: "fiveHour", label: "5 小时窗口", item: obj,
                totalKey: "current_interval_total_count", remainingKey: "current_interval_usage_count",
                remainingPercentKey: "current_interval_remaining_percent", endKey: "end_time") {
                if interval == nil || (candidate.percentage ?? 0) > (interval?.percentage ?? 0) {
                    interval = candidate
                }
            }
            if let candidate = minimaxWindowFromItem(
                key: "week", label: "周额度", item: obj,
                totalKey: "current_weekly_total_count", remainingKey: "current_weekly_usage_count",
                remainingPercentKey: "current_weekly_remaining_percent", endKey: "weekly_end_time") {
                if week == nil || (candidate.percentage ?? 0) > (week?.percentage ?? 0) {
                    week = candidate
                }
            }
        }
        var windows: [QuotaWindow] = []
        if let interval { windows.append(interval) }
        if let week { windows.append(week) }
        return finalizeAccount(kind: .minimax, label: LABEL,
                               windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .minimax, label: LABEL,
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func minimaxAccount(_ home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    // home 未用：MiniMax 凭据只来自 env，仅为统一签名保留
    guard let auth = readMiniMaxAuth(env) else { return missingAccount(.minimax, LABEL, now) }
    return await fetchMiniMaxAccount(auth, doFetch, now)
}
