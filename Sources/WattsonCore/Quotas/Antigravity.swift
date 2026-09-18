// Quotas/Antigravity.swift — Google Antigravity 订阅额度：凭据 = 系统 Keychain
// （service=gemini, account=antigravity，go-keyring-base64 编码的 OAuth JSON），
// 临期用 Antigravity 内置 OAuth client 静默刷新；loadCodeAssist（ideType=ANTIGRAVITY）
// → retrieveUserQuotaSummary，取 Gemini / Claude & GPT 两组的 5 小时窗口与周额度。
// 云端直连不要求 Antigravity 应用在运行；本地 language_server 端口探测不在此实现
// （无凭据时明确报 no_credentials，避免为兜底引入 lsof/自签 TLS 两个复杂面）。
// 刷新得到的 access_token 仅内存使用（不回写 Keychain，避免破坏 go-keyring 格式）。
// OAuth client 不硬编码（对齐 Gemini.swift 的既有约定）：env 显式提供优先，否则
// 扫描本机安装的 language_server 二进制抽取候选，刷新时逐对尝试并缓存命中对。
import Foundation

private let antigravityLabel = "Antigravity"

private let tokenURL = "https://oauth2.googleapis.com/token"
private let codeAssistBase = "https://cloudcode-pa.googleapis.com/v1internal"

public struct AntigravityCreds: Sendable, Equatable {
    public var accessToken: String?
    public var refreshToken: String?
    /// 绝对毫秒时间戳（Keychain 里是 ISO 字符串，读取时归一）
    public var expiryMs: Double?
    /// env 显式提供的 OAuth client（ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET）；可空
    public var clientId: String?
    public var clientSecret: String?
    public init(accessToken: String?, refreshToken: String?, expiryMs: Double?,
                clientId: String? = nil, clientSecret: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryMs = expiryMs
        self.clientId = clientId
        self.clientSecret = clientSecret
    }
}

/// 纯文本错误（无 HTTP 状态码）
private struct AntigravityError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Keychain 凭据读取

/// 运行系统 security CLI（生产路径；Proxy.swift runScutilProxy 同款写法）
public func runSecurityKeychain(service: String, account: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    p.arguments = ["find-generic-password", "-s", service, "-a", account, "-w"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

/// ISO8601（含/不含小数秒、带时区偏移）→ 毫秒；非法为 nil
func antigravityISOMs(_ raw: String) -> Double? {
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let date = fractional.date(from: raw) ?? plain.date(from: raw)
    return date.map { $0.timeIntervalSince1970 * 1000 }
}

/// go-keyring-base64 前缀的 security CLI 原始输出 → 凭据；形状不对为 nil
public func parseAntigravityKeychainOutput(_ raw: String) -> AntigravityCreds? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let prefix = "go-keyring-base64:"
    guard trimmed.hasPrefix(prefix) else { return nil }
    guard let data = Data(base64Encoded: String(trimmed.dropFirst(prefix.count))) else { return nil }
    guard let obj = (try? JSON.parse(data))?.obj else { return nil }
    return antigravityCredsFromJSON(obj)
}

private func antigravityCredsFromJSON(_ obj: [String: JSON]) -> AntigravityCreds? {
    let token = obj["token"]?.obj
    guard let refreshToken = quotaStr(token?["refresh_token"]) else { return nil }
    let expiryMs = quotaStr(token?["expiry"]).flatMap(antigravityISOMs)
        ?? quotaNum(token?["expiry"])
    return AntigravityCreds(
        accessToken: quotaStr(token?["access_token"]),
        refreshToken: refreshToken,
        expiryMs: expiryMs)
}

/// 凭据来源：ANTIGRAVITY_KEYCHAIN_JSON 注入（测试/覆盖）优先，其次真实 Keychain；
/// ANTIGRAVITY_KEYCHAIN=0/false 显式停用。env 提供的 OAuth client 附在凭据上。
public func readAntigravityCreds(_ env: [String: String]) -> AntigravityCreds? {
    let flag = env["ANTIGRAVITY_KEYCHAIN"]?.trimmingCharacters(in: .whitespaces).lowercased()
    if flag == "0" || flag == "false" { return nil }
    let injected = env["ANTIGRAVITY_KEYCHAIN_JSON"]?.trimmingCharacters(in: .whitespaces)
    var creds: AntigravityCreds?
    if injected != nil {
        // 注入路径独立：形状不对直接失败，绝不跌落到真实 Keychain（测试确定性）
        guard !injected!.isEmpty, let data = injected!.data(using: .utf8),
              let obj = (try? JSON.parse(data))?.obj,
              let parsed = antigravityCredsFromJSON(obj) else { return nil }
        creds = parsed
    } else {
        creds = parseAntigravityKeychainOutput(runSecurityKeychain(service: "gemini", account: "antigravity"))
    }
    guard var creds else { return nil }
    creds.clientId = env["ANTIGRAVITY_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespaces)
    creds.clientSecret = env["ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespaces)
    return creds
}

// MARK: - OAuth client 发现（env 优先，其次本机安装二进制抽取）

/// 本机 Antigravity language_server 二进制的候选路径（ANTIGRAVITY_APP_BIN 优先）
public func antigravityBinaryCandidates(env: [String: String]) -> [String] {
    var candidates: [String] = []
    if let bin = env["ANTIGRAVITY_APP_BIN"]?.trimmingCharacters(in: .whitespaces), !bin.isEmpty {
        candidates.append(bin)
    }
    candidates.append("/Applications/Antigravity.app/Contents/Resources/bin/language_server")
    return candidates
}

/// 从二进制字节流里抽取 OAuth client 候选：id 形如「数字-小写字母数字@32 位宽松版」，
/// secret 形如 GOCSPX- 令牌。宽松度仅够工程用，不构成对真实凭据值的匹配。
func scanOAuthCandidates(_ data: Data) -> (ids: [String], secrets: [String]) {
    let idMarker = Data("apps.googleusercontent.com".utf8)
    let secretMarker = Data("GOCSPX-".utf8)
    // id 回走含 '.'：marker 前的分隔点也要走进 span（后面 trim 掉）
    let idTailAllowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-_".utf8)
    let secretAllowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-".utf8)

    var ids: [String] = []
    var secrets: [String] = []
    var searchStart = data.startIndex
    while let r = data.range(of: idMarker, options: [], in: searchStart..<data.endIndex) {
        var head = r.lowerBound
        var steps = 0
        while head > data.startIndex, steps < 200,
              let prev = data.index(head, offsetBy: -1, limitedBy: data.startIndex),
              idTailAllowed.contains(data[prev]) {
            head = prev
            steps += 1
        }
        // id 主体在 marker 之前；前面可能粘连字符串常量垃圾（如 "…it1071006…"），
        // 先 trim 掉 marker 分隔点，再用后缀锚定正则取「数字-尾段」的最终形态
        var span = String(data: data[head..<r.lowerBound], encoding: .utf8) ?? ""
        while span.hasSuffix(".") { span.removeLast() }
        if let m = span.range(of: "[0-9]{6,}-[a-z0-9_-]{8,}$", options: .regularExpression) {
            ids.append(String(span[m]))
        }
        searchStart = r.upperBound
    }
    searchStart = data.startIndex
    while let r = data.range(of: secretMarker, options: [], in: searchStart..<data.endIndex) {
        var tail = r.upperBound
        var steps = 0
        while tail < data.endIndex, steps < 64,
              secretAllowed.contains(data[tail]) == true {
            tail = data.index(after: tail)
            steps += 1
        }
        if tail > r.upperBound,
           let token = String(data: data[r.upperBound..<tail], encoding: .utf8) {
            // Go 字符串常量 blob 相邻拼接：真实 secret 后面可能紧跟下一个常量
            //（如另一个 GOCSPX- 值或 "https"），按内部分隔符切分，逐段成为候选
            for part in token.components(separatedBy: "GOCSPX-") where part.count >= 16 {
                secrets.append("GOCSPX-" + part)
            }
        }
        searchStart = r.upperBound
    }
    return (ids, secrets)
}

/// 进程级缓存：抽取结果与刷新命中的 (id, secret) 对
final class AntigravityClientCache: @unchecked Sendable {
    static let shared = AntigravityClientCache()
    private let lock = NSLock()
    private var scanned = false
    private var candidates: (ids: [String], secrets: [String])?
    private var winner: (id: String, secret: String)?

    func extracted(env: [String: String], readFile: (String) -> Data?) -> (ids: [String], secrets: [String])? {
        lock.lock(); defer { lock.unlock() }
        if !scanned {
            scanned = true
            for path in antigravityBinaryCandidates(env: env) {
                if let data = readFile(path), data.count < 512 * 1024 * 1024 {
                    let found = scanOAuthCandidates(data)
                    if !found.ids.isEmpty, !found.secrets.isEmpty {
                        candidates = found
                        break
                    }
                }
            }
        }
        return candidates
    }

    func currentWinner() -> (id: String, secret: String)? {
        lock.lock(); defer { lock.unlock() }
        return winner
    }

    func storeWinner(id: String, secret: String) {
        lock.lock(); defer { lock.unlock() }
        winner = (id, secret)
    }
}

// MARK: - Token 刷新

private func formEncode(_ value: String) -> String {
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

private func refreshRequest(_ clientId: String, _ clientSecret: String, _ refreshToken: String) -> FetchRequest {
    let form = [
        "client_id=\(formEncode(clientId))",
        "client_secret=\(formEncode(clientSecret))",
        "refresh_token=\(formEncode(refreshToken))",
        "grant_type=refresh_token",
    ].joined(separator: "&")
    return FetchRequest(
        url: tokenURL, method: "POST",
        headers: ["content-type": "application/x-www-form-urlencoded"], body: form)
}

/// 过期（< now+5min）时静默刷新：凭据上的 env client 优先，其次本机二进制抽取的
/// 候选逐对尝试（命中对进程级缓存）；全部失败返回原 access_token，由后续 API 报 401
func ensureAntigravityAccessToken(_ creds: AntigravityCreds, env: [String: String],
                                  readFile: @Sendable (String) -> Data? = { try? Data(contentsOf: URL(fileURLWithPath: $0)) },
                                  _ doFetch: FetchLike, _ now: Double) async -> String? {
    if let token = creds.accessToken, (creds.expiryMs.map { $0 > now + 300_000 } ?? true) {
        return token
    }
    guard let refreshToken = creds.refreshToken else { return creds.accessToken }

    var pairs: [(id: String, secret: String)] = []
    if let id = creds.clientId, let secret = creds.clientSecret {
        pairs.append((id, secret))
    } else if let cached = AntigravityClientCache.shared.currentWinner() {
        pairs.append(cached)
    } else if let found = AntigravityClientCache.shared.extracted(env: env, readFile: readFile) {
        for id in found.ids {
            for secret in found.secrets {
                pairs.append((id, secret))
            }
        }
    }
    for pair in pairs {
        do {
            let res = try await doFetch(refreshRequest(pair.id, pair.secret, refreshToken))
            guard res.ok, let newToken = quotaStr(res.body["access_token"]) else { continue }
            AntigravityClientCache.shared.storeWinner(id: pair.id, secret: pair.secret)
            return newToken
        } catch {
            continue
        }
    }
    return creds.accessToken
}

// MARK: - Code Assist 拉取与归一

/// 组名 → 窗口 key 前缀：Gemini 组在前，其余（Claude and GPT models 等）归 claude
private func groupPrefix(_ groupName: String) -> (key: String, label: String) {
    if groupName.range(of: "gemini", options: .caseInsensitive) != nil {
        return ("gemini", "Gemini")
    }
    return ("claude", "Claude & GPT")
}

/// retrieveUserQuotaSummary 响应 → 已用百分比窗口（兼容顶层 response 包裹）
public func parseAntigravityQuotaSummary(_ body: JSON) -> [QuotaWindow] {
    let root = body["response"]?.obj ?? body.obj
    guard let groups = root?["groups"]?.arr else { return [] }
    var windows: [QuotaWindow] = []
    for group in groups {
        guard let g = group.obj else { continue }
        let groupName = quotaStr(g["displayName"]) ?? ""
        let prefix = groupPrefix(groupName)
        for bucket in g["buckets"]?.arr ?? [] {
            guard let b = bucket.obj else { continue }
            let name = quotaStr(b["displayName"]) ?? quotaStr(b["bucketId"]) ?? ""
            if name.isEmpty { continue }
            let fraction = quotaNum(b["remainingFraction"])
                ?? quotaNum(b["remaining"]?.obj?["remainingFraction"])
            guard let fraction else { continue }
            let lower = name.lowercased()
            let isFiveHour = lower.contains("five") || lower.contains("5 h") || lower.contains("5h")
            let isWeek = lower.contains("week")
            let used = min(100, max(0, (1 - fraction) * 100))
            windows.append(QuotaWindow(
                key: isFiveHour ? "\(prefix.key)-fiveHour" : isWeek ? "\(prefix.key)-week" : "\(prefix.key)-\(name)",
                label: "\(prefix.label) \(isFiveHour ? "5小时" : isWeek ? "周额度" : name)",
                usedPercent: used, percentage: used,
                nextResetAt: toEpochMs(b["resetTime"])))
        }
    }
    // Gemini 组在前、Claude & GPT 在后；组内 5 小时在前、周在后
    let rank: (QuotaWindow) -> (Int, Int) = { w in
        let gemini = w.key.hasPrefix("gemini") ? 0 : 1
        return (gemini, w.key.contains("fiveHour") ? 0 : 1)
    }
    return windows.sorted { rank($0) < rank($1) }
}

private func loadAntigravityCodeAssist(_ token: String, _ doFetch: FetchLike) async throws -> (plan: String?, project: String?) {
    let result = try await quotaFetchJson(
        doFetch, "\(codeAssistBase):loadCodeAssist", method: "POST",
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: "{\"metadata\":{\"ideType\":\"ANTIGRAVITY\",\"pluginType\":\"GEMINI\"}}")
    let root = result.body
    let plan = quotaStr(root["planName"])
        ?? quotaStr(root["paidTier"]?.obj?["name"])
        ?? quotaStr(root["currentTier"]?.obj?["name"])
        ?? quotaStr(root["currentTier"])
    return (plan, quotaStr(root["cloudaicompanionProject"]))
}

private func retrieveAntigravitySummary(_ token: String, _ project: String?, _ doFetch: FetchLike) async throws -> [QuotaWindow] {
    let payload = JSON.obj(project.map { ["project": JSON.str($0)] } ?? [:])
    let body = (try? payload.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let res = try await quotaFetchJson(
        doFetch, "\(codeAssistBase):retrieveUserQuotaSummary", method: "POST",
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: body)
    let windows = parseAntigravityQuotaSummary(res.body)
    if windows.isEmpty { throw AntigravityError(message: "配额响应缺少 groups 数据") }
    return windows
}

public func fetchAntigravityAccount(_ creds: AntigravityCreds, env: [String: String] = [:],
                                    readFile: @Sendable (String) -> Data? = { try? Data(contentsOf: URL(fileURLWithPath: $0)) },
                                    _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    guard let token = await ensureAntigravityAccessToken(creds, env: env, readFile: readFile, doFetch, now) else {
        return finalizeAccount(kind: .antigravity, label: antigravityLabel,
                               error: "凭据缺少 access_token 且无法刷新（未找到本机 Antigravity 安装，或未配置 ANTIGRAVITY_OAUTH_CLIENT_ID/SECRET）",
                               httpStatus: 401, now: now)
    }
    do {
        // loadCodeAssist 失败不阻塞配额查询（套餐名尽力而为）
        let status: (plan: String?, project: String?)
        do {
            status = try await loadAntigravityCodeAssist(token, doFetch)
        } catch {
            status = (nil, nil)
        }
        let windows = try await retrieveAntigravitySummary(token, status.project, doFetch)
        return finalizeAccount(
            kind: .antigravity, label: antigravityLabel,
            planName: status.plan, windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .antigravity, label: antigravityLabel,
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func antigravityAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let creds = readAntigravityCreds(env) else { return missingAccount(.antigravity, antigravityLabel, now) }
    return await fetchAntigravityAccount(creds, env: env, doFetch, now)
}
