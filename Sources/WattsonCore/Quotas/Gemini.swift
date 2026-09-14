// Quotas/Gemini.swift — Gemini CLI（oauth-personal）订阅额度：凭据 = ~/.gemini/oauth_creds.json
// （access_token/refresh_token/expiry_date），settings.json 的 selectedType 不能是 api-key；
// 过期时用 refresh_token + OAuth client（env 或从本机 gemini-cli 安装文件里抽取）刷新并回写；
// loadCodeAssist → retrieveUserQuota，buckets 按模型取最低剩余比例。
import Foundation

public struct GeminiCreds: Sendable, Equatable {
    public var accessToken: String?
    public var refreshToken: String?
    public var expiryMs: Double?
    /// 已解析/抽取到的 OAuth client；用于静默刷新
    public var clientId: String?
    public var clientSecret: String?
    public var credsPath: String
    public init(accessToken: String?, refreshToken: String?, expiryMs: Double?,
                clientId: String?, clientSecret: String?, credsPath: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiryMs = expiryMs
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.credsPath = credsPath
    }
}

private let geminiLabel = "Gemini"

private let geminiTierNames: [String: String] = [
    "free-tier": "Free",
    "legacy-tier": "Legacy",
    "standard-tier": "Standard",
]

/// 纯文本错误（无 HTTP 状态码）
private struct GeminiError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 正则第 1 个捕获组（TS content.match(re)?.[1] 口径）
private func firstRegexCapture(_ pattern: String, _ content: String) -> String? {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(content.startIndex..., in: content)
    guard let m = re.firstMatch(in: content, options: [], range: range),
          m.numberOfRanges > 1, let captured = Range(m.range(at: 1), in: content) else { return nil }
    return String(content[captured])
}

/// gemini-cli 安装里 oauth2.js 的候选路径（有 GEMINI_OAUTH2_JS_PATH/GEMINI_CLI_HOME 则优先）
public func oauth2JsCandidates(_ home: String, _ env: [String: String]) -> [String] {
    let direct = env["GEMINI_OAUTH2_JS_PATH"]?.trimmingCharacters(in: .whitespaces)
    let cliHome = env["GEMINI_CLI_HOME"]?.trimmingCharacters(in: .whitespaces)
    let fixed = [
        "/opt/homebrew/lib/node_modules/@google/gemini-cli",
        "/usr/local/lib/node_modules/@google/gemini-cli",
        (home as NSString).appendingPathComponent(".bun/install/global/node_modules/@google/gemini-cli"),
    ]
    var roots: [String] = []
    if let cliHome { roots.append(cliHome) }
    let nvmDir = (home as NSString).appendingPathComponent(".nvm/versions/node")
    for version in listDirectory(nvmDir) {
        roots.append((nvmDir as NSString).appendingPathComponent("\(version)/lib/node_modules/@google/gemini-cli"))
    }
    roots.append(contentsOf: fixed)
    var candidates: [String] = []
    if let direct { candidates.append(direct) }
    for root in roots {
        candidates.append((root as NSString).appendingPathComponent("dist/src/code_assist/oauth2.js"))
        candidates.append((root as NSString).appendingPathComponent("src/code_assist/oauth2.js"))
    }
    return candidates
}

public func extractOAuthClient(_ home: String, _ env: [String: String]) -> (clientId: String, clientSecret: String)? {
    let clientId = env["GEMINI_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespaces)
    let clientSecret = env["GEMINI_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespaces)
    if let clientId, let clientSecret { return (clientId, clientSecret) }
    for path in oauth2JsCandidates(home, env) {
        guard fileExists(path), let content = readTextFile(path) else { continue }
        let id = firstRegexCapture("(?:client_id|CLIENT_ID)['\"`]?\\s*[:=]\\s*['\"]([^'\"]+)['\"]", content)
        let secret = firstRegexCapture("(?:client_secret|CLIENT_SECRET)['\"`]?\\s*[:=]\\s*['\"]([^'\"]+)['\"]", content)
        if let id, let secret { return (id, secret) }
    }
    return nil
}

/// 凭据：~/.gemini/oauth_creds.json；settings.json 明确选了 API key 模式 → 没有订阅额度可看
public func readGeminiCreds(_ home: String, _ env: [String: String]) -> GeminiCreds? {
    // 无 settings.json（老版本默认 oauth-personal）→ 继续
    let geminiHome = (home as NSString).appendingPathComponent(".gemini")
    if let settings = parseJSONFile((geminiHome as NSString).appendingPathComponent("settings.json")),
       settings["security"]?["auth"]?["selectedType"] == .str("api-key") {
        return nil
    }
    let credsPath = (geminiHome as NSString).appendingPathComponent("oauth_creds.json")
    guard let parsed = parseJSONFile(credsPath) else { return nil }
    guard !parsed.isNull, parsed.obj != nil || parsed.arr != nil else { return nil }
    let client = extractOAuthClient(home, env)
    return GeminiCreds(
        accessToken: quotaStr(parsed["access_token"]),
        refreshToken: quotaStr(parsed["refresh_token"]),
        expiryMs: quotaNum(parsed["expiry_date"]),
        clientId: client?.clientId,
        clientSecret: client?.clientSecret,
        credsPath: credsPath)
}

/// application/x-www-form-urlencoded 值编码（对应 TS new URLSearchParams(...).toString()）
private func formEncode(_ value: String) -> String {
    // query 字符集剔除分隔符 & = ? +：值内这些字符必须转义（+ 在表单里是空格）
    let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=?+"))
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}

/// access_token 过期（< now+60s）时尝试静默刷新并回写 oauth_creds.json；失败返回原值由 API 报 401
public func ensureFreshAccessToken(_ creds: GeminiCreds, _ doFetch: FetchLike, _ now: Double) async -> String? {
    let fresh = creds.accessToken != nil && (creds.expiryMs.map { $0 > now + 60_000 } ?? true)
    if fresh, let token = creds.accessToken { return token }
    guard let refreshToken = creds.refreshToken, let clientId = creds.clientId,
          let clientSecret = creds.clientSecret else { return creds.accessToken }
    do {
        let form = [
            "client_id=\(formEncode(clientId))",
            "client_secret=\(formEncode(clientSecret))",
            "refresh_token=\(formEncode(refreshToken))",
            "grant_type=refresh_token",
        ].joined(separator: "&")
        let res = try await doFetch(FetchRequest(
            url: "https://oauth2.googleapis.com/token", method: "POST",
            headers: ["content-type": "application/x-www-form-urlencoded"], body: form))
        guard res.ok else { return creds.accessToken }
        let json = res.body
        guard let newToken = quotaStr(json["access_token"]) else { return creds.accessToken }
        let expiresIn = quotaNum(json["expires_in"])
        // 回写失败不影响本轮读取
        if var updated = parseJSONFile(creds.credsPath)?.obj {
            updated["access_token"] = .str(newToken)
            if let expiresIn { updated["expiry_date"] = .num(now + expiresIn * 1000) }
            if let rawIdToken = json["id_token"], quotaStr(rawIdToken) != nil { updated["id_token"] = rawIdToken }
            if let data = try? JSON.obj(updated).encoded(pretty: true),
               let out = String(data: data, encoding: .utf8) {
                _ = writeTextFile(creds.credsPath, out)
            }
        }
        return newToken
    } catch {
        return creds.accessToken
    }
}

private struct CodeAssistStatus {
    var tier: String?
    var projectId: String?
}

private func loadCodeAssistStatus(_ token: String, _ doFetch: FetchLike) async throws -> CodeAssistStatus {
    let result = try await quotaFetchJson(
        doFetch, "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist", method: "POST",
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: "{\"metadata\":{\"ideType\":\"GEMINI_CLI\",\"pluginType\":\"GEMINI\"}}")
    let root = result.body
    let projectRaw = root["cloudaicompanionProject"]
    return CodeAssistStatus(
        tier: quotaStr(root["currentTier"]),
        projectId: quotaStr(projectRaw) ?? quotaStr(projectRaw?["id"]))
}

/// 兜底项目发现：gen-lang-client* 前缀或带 generative-language 标签的项目
private func discoverProjectId(_ token: String, _ doFetch: FetchLike) async -> String? {
    do {
        let result = try await quotaFetchJson(
            doFetch, "https://cloudresourcemanager.googleapis.com/v1/projects",
            headers: ["authorization": "Bearer \(token)", "accept": "application/json"])
        guard let projects = result.body["projects"]?.arr else { return nil }
        for project in projects {
            guard let id = quotaStr(project["projectId"]) else { continue }
            if id.hasPrefix("gen-lang-client") { return id }
            if project["labels"]?.obj?["generative-language"] != nil { return id }
        }
    } catch {
        // 项目发现是尽力而为
    }
    return nil
}

private func retrieveUserQuota(_ token: String, _ projectId: String?, _ doFetch: FetchLike) async throws -> [JSON] {
    let payload = JSON.obj(projectId.map { ["project": JSON.str($0)] } ?? [:])
    let body = (try? payload.encoded()).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    let res = try await quotaFetchJson(
        doFetch, "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota", method: "POST",
        headers: ["authorization": "Bearer \(token)", "content-type": "application/json"],
        body: body)
    return res.body["buckets"]?.arr ?? []
}

public func fetchGeminiAccount(_ creds: GeminiCreds, _ doFetch: FetchLike, _ now: Double) async -> QuotaAccount {
    do {
        let token = await ensureFreshAccessToken(creds, doFetch, now)
        guard let token else { throw GeminiError(message: "oauth_creds.json 缺少 access_token 且无法刷新") }

        // loadCodeAssist 失败不阻塞配额查询
        let status: CodeAssistStatus
        do {
            status = try await loadCodeAssistStatus(token, doFetch)
        } catch {
            status = CodeAssistStatus(tier: nil, projectId: nil)
        }
        let projectId: String?
        if let known = status.projectId {
            projectId = known
        } else {
            projectId = await discoverProjectId(token, doFetch)
        }
        let buckets = try await retrieveUserQuota(token, projectId, doFetch)
        if buckets.isEmpty { throw GeminiError(message: "配额响应缺少 buckets 数据") }

        // 每个模型取最低 remaining_fraction 的桶（通常 input 侧先到限）
        var entries: [(modelId: String, fraction: Double, resetAt: Double?)] = []
        for raw in buckets {
            guard let bucket = raw.obj else { continue }
            guard let modelId = quotaStr(bucket["model_id"]),
                  let fraction = quotaNum(bucket["remaining_fraction"]) else { continue }
            if let idx = entries.firstIndex(where: { $0.modelId == modelId }) {
                if fraction < entries[idx].fraction {
                    entries[idx] = (modelId, fraction, toEpochMs(bucket["reset_time"]))
                }
            } else {
                entries.append((modelId, fraction, toEpochMs(bucket["reset_time"])))
            }
        }
        var windows = entries.map { entry -> QuotaWindow in
            let used = min(100, max(0, (1 - entry.fraction) * 100))
            return QuotaWindow(key: entry.modelId, label: entry.modelId,
                               usedPercent: used, percentage: used, nextResetAt: entry.resetAt)
        }
        // 百分比降序，同分保持出现顺序（对齐 TS Map 插入序 + 稳定排序），只留前 6 个模型
        windows = windows.enumerated().sorted { a, b in
            let pa = a.element.percentage ?? 0
            let pb = b.element.percentage ?? 0
            return pa != pb ? pa > pb : a.offset < b.offset
        }.map(\.element)
        windows = Array(windows.prefix(6))

        return finalizeAccount(
            kind: .gemini, label: geminiLabel,
            planName: status.tier.flatMap { geminiTierNames[$0] ?? $0 },
            windows: windows, anySuccess: true, now: now)
    } catch {
        return finalizeAccount(kind: .gemini, label: geminiLabel,
                               error: errText(error), httpStatus: readHttpStatus(error).map(Double.init), now: now)
    }
}

public func geminiAccount(home: String, env: [String: String], doFetch: FetchLike, now: Double) async -> QuotaAccount {
    guard let creds = readGeminiCreds(home, env) else { return missingAccount(.gemini, geminiLabel, now) }
    return await fetchGeminiAccount(creds, doFetch, now)
}
