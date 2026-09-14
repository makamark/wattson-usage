// Quotas/Plan.swift — 订阅账号（GLM Coding Plan / ZCode）用量额度。
// 走官方接口：
//   GET {host}/api/biz/subscription/list       → 套餐订阅明细（productName/billingCycle/有效期）
//   GET {host}/api/monitor/usage/quota/limit   → 额度窗口 data.limits[]（5 小时窗口/周）+ data.level
// 认证 = ~/.zcode/v2/credentials.json 中 coding-plan 账号的 api-key（zcode CLI 的
// `enc:v1:` AES-256-GCM 方案加密，密钥 = SHA256("zcode-credential-fallback:{platform}:{home}:{user}")，
// 可被 ZCODE_CREDENTIAL_SECRET 覆盖）；或直接用 BIGMODEL_USAGE_API_KEY / ZCODE_BIGMODEL_USAGE_API_KEY。
// 凭据只留在服务端内存：/api/plan 只回传额度数据，绝不回传 key/JWT。
import CryptoKit
import Foundation

public struct PlanWindow: Sendable, Equatable {
    /// fiveHour | week | unit-<n>
    public var key: String
    /// 展示名（如「5 小时窗口」「周」）
    public var label: String
    /// 总额度（usage 字段，prompt/credit 数）
    public var total: Double
    /// 已用（currentValue）
    public var used: Double
    public var remaining: Double
    /// 官方百分比（0-100），缺失为 nil
    public var percentage: Double?
    /// 本窗口重置时间（ms epoch），缺失为 nil
    public var nextResetAt: Double?

    public init(key: String, label: String, total: Double, used: Double, remaining: Double,
                percentage: Double?, nextResetAt: Double?) {
        self.key = key
        self.label = label
        self.total = total
        self.used = used
        self.remaining = remaining
        self.percentage = percentage
        self.nextResetAt = nextResetAt
    }
}

public struct PlanSnapshot: Sendable, Equatable {
    public var available: Bool
    /// no_credentials | loading | http_401 | http_error | no_plan | error
    public var unavailableReason: String?
    public var error: String?
    /// coding-plan providerId（如 bigmodel-individual-coding-plan）
    public var provider: String?
    public var planName: String?
    public var level: String?
    public var billingCycle: String?
    public var validFrom: String?
    public var validTo: String?
    public var autoRenew: Bool?
    public var windows: [PlanWindow]
    public var fetchedAt: Double
    public var lastSuccessAt: Double?
}

public let PLAN_TTL_MS: Double = 5 * 60 * 1000

// MARK: - 凭据解密（与 zcode CLI 同方案的只读复刻）

public func credentialSecret(home: String, platform: String, user: String, env: [String: String]) -> String {
    if let fromEnv = env["ZCODE_CREDENTIAL_SECRET"], !fromEnv.isEmpty { return fromEnv }
    return "zcode-credential-fallback:\(platform):\(home):\(user)"
}

/// `enc:v1:nonce.tag.data`（各段 base64url）→ AES-256-GCM 解密；非 enc:v1 原样返回
public func decryptCredential(_ value: String, secret: String) -> String? {
    let prefix = "enc:v1:"
    guard value.hasPrefix(prefix) else { return value }
    let body = value.dropFirst(prefix.count)
    let parts = body.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3,
          let nonceData = base64URLDecode(parts[0]), nonceData.count == 12,
          let tagData = base64URLDecode(parts[1]), tagData.count == 16,
          let cipherData = base64URLDecode(parts[2]) else { return nil }
    let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
    guard let nonce = try? AES.GCM.Nonce(data: nonceData),
          let sealed = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: cipherData, tag: tagData),
          let decrypted = try? AES.GCM.open(sealed, using: key) else { return nil }
    return String(data: decrypted, encoding: .utf8)
}

/// 测试/工具侧加密器（与 zcode CLI enc:v1 方案一致）
public func encryptCredential(_ plain: String, secret: String) -> String? {
    let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
    guard let sealed = try? AES.GCM.seal(Data(plain.utf8), using: key) else { return nil }
    return "enc:v1:\(base64URLEncode(sealed.nonce.withUnsafeBytes { Data($0) }))."
        + "\(base64URLEncode(sealed.tag)).\(base64URLEncode(sealed.ciphertext))"
}

/// zcode 的 api-key 头归一化：剥 Bearer、取 id.secret 形态（口径同 ZCode 桌面端）
public func normalizeApiKey(_ raw: String) -> String? {
    var stripped = raw.trimmingCharacters(in: .whitespaces)
    if stripped.lowercased().hasPrefix("bearer ") {
        stripped = String(stripped.dropFirst(7)).trimmingCharacters(in: .whitespaces)
    }
    // [A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,} 取第一处
    let pattern = "[A-Za-z0-9_-]{8,}\\.[A-Za-z0-9_-]{8,}"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return stripped.isEmpty ? nil : stripped }
    let range = NSRange(stripped.startIndex..., in: stripped)
    if let m = regex.firstMatch(in: stripped, range: range),
       let r = Range(m.range, in: stripped) {
        return String(stripped[r])
    }
    return stripped.isEmpty ? nil : stripped
}

public struct CodingPlanAuth: Sendable, Equatable {
    public var authorization: String
    public var host: String
    public var provider: String
    public init(authorization: String, host: String, provider: String) {
        self.authorization = authorization
        self.host = host
        self.provider = provider
    }
}

func resolveV2Dir(_ home: String) -> String {
    // setting.json 的 dataBaseDir 可重定向 zcode 数据目录
    if let setting = parseJSONFile((home as NSString).appendingPathComponent(".zcode/v2/setting.json")),
       let dir = quotaStr(setting["dataBaseDir"]) {
        return (dir as NSString).appendingPathComponent(".zcode/v2")
    }
    return (home as NSString).appendingPathComponent(".zcode/v2")
}

/// 解析本机 zcode 凭据里的 coding-plan api-key；env 显式提供时优先（与桌面端口径一致）
public func readCodingPlanAuth(_ home: String, _ env: [String: String]) -> CodingPlanAuth? {
    let envKey = env["ZCODE_BIGMODEL_USAGE_API_KEY"] ?? env["BIGMODEL_USAGE_API_KEY"]
    if let envKey, !envKey.trimmingCharacters(in: .whitespaces).isEmpty {
        if let key = normalizeApiKey(envKey) {
            return CodingPlanAuth(authorization: key, host: "https://bigmodel.cn", provider: "env:bigmodel-usage")
        }
    }
    let platform = "darwin"
    let user = NSUserName()
    let secret = credentialSecret(home: home, platform: platform, user: user, env: env)
    let v2Dir = resolveV2Dir(home)
    guard let parsed = parseJSONFile((v2Dir as NSString).appendingPathComponent("credentials.json")),
          let entries = parsed.obj else { return nil }
    // 键排序保证确定性（TS 侧依赖 Object.entries 插入序；这里键形如唯一匹配，语义一致）
    var candidates: [(name: String, provider: String, host: String, key: String?)] = []
    for (name, value) in entries.sorted(by: { $0.key < $1.key }) {
        // 键形如 account-provider:coding-plan:account:<providerId>:account:<customerId>:api-key
        let pattern = "^account-provider:coding-plan:account:([^:]+):account:[^:]+:api-key$"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
              let providerRange = Range(m.range(at: 1), in: name) else { continue }
        guard let rawValue = value.str else { continue }
        let provider = String(name[providerRange])
        let host = provider.hasPrefix("zai") ? "https://zcode.z.ai" : "https://bigmodel.cn"
        let decrypted = decryptCredential(rawValue, secret: secret)
        let key = decrypted.flatMap { normalizeApiKey($0) }
        candidates.append((name, provider, host, key))
    }
    let preferred =
        candidates.first { $0.key != nil && $0.provider.contains("individual-coding-plan") }
        ?? candidates.first { $0.key != nil }
    guard let picked = preferred, let key = picked.key else { return nil }
    return CodingPlanAuth(authorization: key, host: picked.host, provider: picked.provider)
}

// MARK: - 响应归一化（纯函数，测试用 fixtures 驱动）

func isOkEnvelope(_ e: JSON) -> Bool {
    let success = e["success"]
    if case .bool(false) = success { return false }
    guard let code = e["code"] else { return true }
    if code.isNull { return true }
    return code.num == 0 || code.num == 200
}

func planNum(_ v: JSON?) -> Double? {
    guard let v, let n = v.num, n.isFinite else { return nil }
    return n
}

func planStr(_ v: JSON?) -> String? { quotaStr(v) }

/// unit 枚举（实测：3=小时、6=周）→ 展示名；未知 unit 给出可读兜底
public func windowLabel(unit: Double?, count: Double?) -> (key: String, label: String) {
    if unit == 3 { return ("fiveHour", "\(Int(count ?? 5)) 小时窗口") }
    if unit == 6 { return ("week", "周额度") }
    if let unit { return ("unit-\(unitKey(unit))", "额度（unit=\(unitKey(unit))\(count.map { "×\(unitKey($0))" } ?? "")）") }
    return ("window", "额度窗口")
}

/// 数值键格式化：整数去小数点
func unitKey(_ n: Double) -> String {
    n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(n)) : String(n)
}

public func parsePlanWindows(_ limits: JSON?) -> [PlanWindow] {
    guard let items = limits?.arr else { return [] }
    var out: [PlanWindow] = []
    for item in items {
        guard let l = item.obj else { continue }
        let total = planNum(l["usage"])
        let used = planNum(l["currentValue"])
        if total == nil && used == nil { continue }
        let (key, label) = windowLabel(unit: planNum(l["unit"]), count: planNum(l["number"]))
        out.append(PlanWindow(
            key: key, label: label,
            total: total ?? 0,
            used: used ?? 0,
            remaining: planNum(l["remaining"]) ?? max(0, (total ?? 0) - (used ?? 0)),
            percentage: planNum(l["percentage"]),
            nextResetAt: planNum(l["nextResetTime"])))
    }
    // 5 小时窗口在前、周在后；其余按 key 稳定排序
    let order: (String) -> Int = { $0 == "fiveHour" ? 0 : $0 == "week" ? 1 : 2 }
    return out.enumerated().sorted { a, b in
        let (oa, ob) = (order(a.element.key), order(b.element.key))
        return oa != ob ? oa < ob : a.offset < b.offset
    }.map(\.element)
}

public struct PlanSubscription: Sendable, Equatable {
    public var planName: String?
    public var billingCycle: String?
    public var validFrom: String?
    public var validTo: String?
    public var autoRenew: Bool?
    public var nextRenewAt: String?
}

public func parseSubscription(_ list: JSON?) -> PlanSubscription {
    let empty = PlanSubscription(planName: nil, billingCycle: nil, validFrom: nil,
                                 validTo: nil, autoRenew: nil, nextRenewAt: nil)
    guard let data = list?["data"], let rows = data.arr else { return empty }
    // 口径同桌面端：优先当前周期且 VALID，其次任一 VALID/当前周期
    let isObj = { (s: JSON) in s.obj != nil }
    let pick =
        rows.first { isObj($0) && $0["inCurrentPeriod"]?.bool == true && $0["status"]?.str == "VALID" }
        ?? rows.first { isObj($0) && $0["inCurrentPeriod"]?.bool == true }
        ?? rows.first { isObj($0) && $0["status"]?.str == "VALID" }
    guard let pick else { return empty }
    let valid = planStr(pick["valid"])
    // valid 形如 "2026-12-09 10:00:00-2027-03-09 10:00:00"
    var validFrom: String? = nil
    var validTo: String? = nil
    if let valid {
        let pattern = "^(\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2})-(\\d{4}-\\d{2}-\\d{2}[ T]\\d{2}:\\d{2}:\\d{2})$"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let m = regex.firstMatch(in: valid, range: NSRange(valid.startIndex..., in: valid)),
           let r1 = Range(m.range(at: 1), in: valid), let r2 = Range(m.range(at: 2), in: valid) {
            validFrom = String(valid[r1])
            validTo = String(valid[r2])
        }
    }
    let autoRaw = pick["autoRenew"]
    var autoRenew: Bool? = nil
    if let b = autoRaw?.bool { autoRenew = b }
    else if autoRaw?.num == 1 { autoRenew = true }
    else if autoRaw?.num == 0 { autoRenew = false }
    return PlanSubscription(
        planName: planStr(pick["productName"]),
        billingCycle: planStr(pick["billingCycle"]),
        validFrom: validFrom,
        validTo: validTo,
        autoRenew: autoRenew,
        nextRenewAt: planStr(pick["nextRenewTime"]))
}

// MARK: - 拉取

public func fetchPlanSnapshot(auth: CodingPlanAuth, doFetch: FetchLike, now: Double) async -> PlanSnapshot {
    var snapshot = PlanSnapshot(
        available: false, unavailableReason: nil, error: nil,
        provider: auth.provider, planName: nil, level: nil, billingCycle: nil,
        validFrom: nil, validTo: nil, autoRenew: nil,
        windows: [], fetchedAt: now, lastSuccessAt: nil)

    func getJson(_ url: String) async throws -> JSON {
        let res = try await doFetch(FetchRequest(url: url, headers: ["authorization": auth.authorization]))
        if res.status == 401 || res.status == 403 {
            throw HTTPStatusError(status: res.status, message: "HTTP \(res.status)（凭据无效或已过期）")
        }
        if !res.ok { throw HTTPStatusError(status: res.status, message: "HTTP \(res.status)") }
        return res.body
    }

    var httpStatus: Int? = nil
    var error: String? = nil
    var successCount = 0

    do {
        let sub = try await getJson("\(auth.host)/api/biz/subscription/list")
        if isOkEnvelope(sub) {
            successCount += 1
            let s = parseSubscription(sub)
            snapshot.planName = s.planName
            snapshot.billingCycle = s.billingCycle
            snapshot.validFrom = s.validFrom
            snapshot.validTo = s.validTo
            snapshot.autoRenew = s.autoRenew
        } else {
            error = planStr(sub["msg"]) ?? "订阅接口返回失败"
        }
    } catch let e {
        httpStatus = readHttpStatus(e) ?? httpStatus
        error = errText(e)
    }

    do {
        let q = try await getJson("\(auth.host)/api/monitor/usage/quota/limit")
        if isOkEnvelope(q) {
            successCount += 1
            snapshot.level = planStr(q["data"]?["level"])
            snapshot.windows = parsePlanWindows(q["data"]?["limits"])
            if snapshot.windows.isEmpty && error == nil {
                error = planStr(q["msg"]) ?? "额度接口未返回窗口数据"
            }
        } else if error == nil {
            error = planStr(q["msg"]) ?? "额度接口返回失败"
        }
    } catch let e {
        httpStatus = readHttpStatus(e) ?? httpStatus
        if error == nil { error = errText(e) }
    }

    snapshot.error = error
    if successCount > 0 {
        snapshot.available = !snapshot.windows.isEmpty || snapshot.planName != nil
        if snapshot.available { snapshot.lastSuccessAt = now }
        else { snapshot.unavailableReason = "no_plan" }
    } else {
        snapshot.unavailableReason = httpStatus == 401 || httpStatus == 403
            ? "http_401" : (httpStatus != nil ? "http_error" : "error")
    }
    return snapshot
}

/// GLM 的 PlanSnapshot（绝对值口径）→ 统一 QuotaAccount（poller 用）
public func glmToAccount(_ s: PlanSnapshot) -> QuotaAccount {
    QuotaAccount(
        kind: .glm, label: "GLM Coding Plan",
        available: s.available, unavailableReason: s.unavailableReason, error: s.error,
        planName: s.planName,
        windows: s.windows.map {
            QuotaWindow(key: $0.key, label: $0.label, total: $0.total, used: $0.used,
                        remaining: $0.remaining, percentage: $0.percentage, nextResetAt: $0.nextResetAt)
        },
        fetchedAt: s.fetchedAt, lastSuccessAt: s.lastSuccessAt)
}
