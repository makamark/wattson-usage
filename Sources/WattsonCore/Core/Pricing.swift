// Core/Pricing.swift — 模型定价与成本计算（原生内嵌价目快照）。
// 口径：
//   · billableOutputTokens：claude/codex/copilot 的 reasoningTokens 是 outputTokens
//     的子集（reasoning-in-output），不得加第二次；其余工具独立推理口径可加。
//   · calculateCost：缓存写入缺省按 1.25×输入、缓存读取缺省按 0.1×输入兜底；
//     未收录模型成本为 $0（合法值，不是缺失）。
import Foundation

public struct ModelCosts: Sendable, Equatable {
    public var inputCostPerToken: Double
    public var outputCostPerToken: Double
    public var cacheWriteCostPerToken: Double
    public var cacheReadCostPerToken: Double
    public var webSearchCostPerRequest: Double
    public var fastMultiplier: Double

    public init(input: Double, output: Double, cacheWrite: Double?, cacheRead: Double?,
                fast: Double? = nil, webSearch: Double = 0.01) {
        self.inputCostPerToken = input
        self.outputCostPerToken = output
        self.cacheWriteCostPerToken = cacheWrite ?? input * 1.25
        self.cacheReadCostPerToken = cacheRead ?? input * 0.1
        self.webSearchCostPerRequest = webSearch
        self.fastMultiplier = fast ?? 1
    }
}

let REASONING_INCLUDED_IN_OUTPUT: Set<String> = ["claude", "codex", "copilot"]

/// 单次调用的计费输出 token。单一事实来源：成本与展示总量永远同口径。
public func billableOutputTokens(provider: String, outputTokens: Double, reasoningTokens: Double) -> Double {
    REASONING_INCLUDED_IN_OUTPUT.contains(provider) ? outputTokens : outputTokens + reasoningTokens
}

// MARK: - 内嵌价目快照（USD / token）
// [input, output, cacheWrite(可空), cacheRead(可空), fast(可空)]
// 数值为 LiteLLM 量级的常用模型价目；缺失的缓存价按兜底倍率推导。

typealias SnapshotEntry = (input: Double, output: Double, cacheWrite: Double?, cacheRead: Double?, fast: Double?)

let PRICING_SNAPSHOT: [String: SnapshotEntry] = [
    // GLM / ZCode
    "glm-5.3": SnapshotEntry(1e-6, 3.2e-6, nil, 0.1e-6, nil),
    "glm-5.2": SnapshotEntry(1e-6, 3.2e-6, nil, 0.1e-6, nil),
    "glm-5": SnapshotEntry(1e-6, 3.2e-6, nil, 0.1e-6, nil),
    "glm-4.6": SnapshotEntry(0.6e-6, 2.2e-6, nil, 0.11e-6, nil),
    "glm-4.5": SnapshotEntry(0.6e-6, 2.2e-6, nil, 0.11e-6, nil),
    "glm-4.5-air": SnapshotEntry(0.2e-6, 1.1e-6, nil, 0.04e-6, nil),
    // Anthropic
    "claude-opus-4-5": SnapshotEntry(5e-6, 25e-6, 6.25e-6, 0.5e-6, nil),
    "claude-opus-4-1": SnapshotEntry(15e-6, 75e-6, 18.75e-6, 1.5e-6, nil),
    "claude-sonnet-4-5": SnapshotEntry(3e-6, 15e-6, 3.75e-6, 0.3e-6, nil),
    "claude-haiku-4-5": SnapshotEntry(1e-6, 5e-6, 1.25e-6, 0.1e-6, nil),
    "claude-sonnet-4": SnapshotEntry(3e-6, 15e-6, 3.75e-6, 0.3e-6, nil),
    "claude-3-7-sonnet": SnapshotEntry(3e-6, 15e-6, 3.75e-6, 0.3e-6, nil),
    "claude-3-5-sonnet": SnapshotEntry(3e-6, 15e-6, 3.75e-6, 0.3e-6, nil),
    "claude-3-5-haiku": SnapshotEntry(0.8e-6, 4e-6, 1e-6, 0.08e-6, nil),
    // OpenAI
    "gpt-5.5-pro": SnapshotEntry(2.5e-6, 20e-6, nil, 0.25e-6, nil),
    "gpt-5.5": SnapshotEntry(1.75e-6, 14e-6, nil, 0.175e-6, nil),
    "gpt-5.4": SnapshotEntry(1.5e-6, 12e-6, nil, 0.15e-6, nil),
    "gpt-5.3-codex": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-5.3": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-5.2-pro": SnapshotEntry(2.5e-6, 20e-6, nil, 0.25e-6, nil),
    "gpt-5.2": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-5.1-codex": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-5.1": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-5-pro": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-5-mini": SnapshotEntry(0.25e-6, 2e-6, nil, 0.025e-6, nil),
    "gpt-5-nano": SnapshotEntry(0.05e-6, 0.4e-6, nil, 0.005e-6, nil),
    "gpt-5": SnapshotEntry(1.25e-6, 10e-6, nil, 0.125e-6, nil),
    "gpt-4.1": SnapshotEntry(2e-6, 8e-6, nil, 0.5e-6, nil),
    "gpt-4.1-mini": SnapshotEntry(0.4e-6, 1.6e-6, nil, 0.1e-6, nil),
    "gpt-4.1-nano": SnapshotEntry(0.1e-6, 0.4e-6, nil, 0.025e-6, nil),
    "gpt-4o": SnapshotEntry(2.5e-6, 10e-6, nil, 1.25e-6, nil),
    "gpt-4o-mini": SnapshotEntry(0.15e-6, 0.6e-6, nil, 0.075e-6, nil),
    "o3": SnapshotEntry(2e-6, 8e-6, nil, 0.5e-6, nil),
    "o4-mini": SnapshotEntry(1.1e-6, 4.4e-6, nil, 0.275e-6, nil),
    // Google
    "gemini-3-pro-preview": SnapshotEntry(2e-6, 12e-6, nil, 0.2e-6, nil),
    "gemini-3-flash-preview": SnapshotEntry(0.5e-6, 3e-6, nil, 0.05e-6, nil),
    "gemini-2.5-pro": SnapshotEntry(1.25e-6, 10e-6, nil, 0.31e-6, nil),
    "gemini-2.5-flash": SnapshotEntry(0.3e-6, 2.5e-6, nil, 0.075e-6, nil),
    // xAI（grok-4.6 有高价位档，见 tieredCosts）
    "grok-4.6": SnapshotEntry(2e-6, 6e-6, nil, 0.5e-6, nil),
    "grok-4": SnapshotEntry(3e-6, 15e-6, nil, 0.75e-6, nil),
    "grok-3": SnapshotEntry(3e-6, 15e-6, nil, 0.75e-6, nil),
    // Moonshot
    "kimi-k3": SnapshotEntry(0.6e-6, 2.5e-6, nil, 0.12e-6, nil),
    "kimi-k2-thinking": SnapshotEntry(0.6e-6, 2.5e-6, nil, 0.12e-6, nil),
    "kimi-k2": SnapshotEntry(0.6e-6, 2.5e-6, nil, 0.12e-6, nil),
    // MiniMax / DeepSeek / Qwen
    "minimax-m2": SnapshotEntry(0.3e-6, 1.2e-6, nil, 0.03e-6, nil),
    "abab-mini": SnapshotEntry(0.3e-6, 1.2e-6, nil, 0.03e-6, nil),
    "deepseek-chat": SnapshotEntry(0.27e-6, 1.1e-6, nil, 0.07e-6, nil),
    "deepseek-reasoner": SnapshotEntry(0.55e-6, 2.19e-6, nil, 0.14e-6, nil),
    "qwen3-coder": SnapshotEntry(0.22e-6, 0.88e-6, nil, 0.055e-6, nil),
    "qwen3-max": SnapshotEntry(1.2e-6, 6e-6, nil, 0.12e-6, nil),
    // 真实语料补充（离线兜底；在线 LiteLLM 快照装载后覆盖更多）
    "claude-opus-4-8": SnapshotEntry(5e-6, 25e-6, 6.25e-6, 0.5e-6, nil),
    "gpt-5.6": SnapshotEntry(1.5e-6, 12e-6, nil, 0.15e-6, nil),
    "gemini-3.7-flash": SnapshotEntry(0.5e-6, 3e-6, nil, 0.05e-6, nil),
    "gemini-3.5-pro": SnapshotEntry(2e-6, 12e-6, nil, 0.2e-6, nil),
    "deepseek-v4": SnapshotEntry(0.3e-6, 1.2e-6, nil, 0.03e-6, nil),
    "deepseek-v4-flash": SnapshotEntry(0.15e-6, 0.6e-6, nil, 0.015e-6, nil),
    // Cursor（官方公布的自家模型价，缓存写 = 输入价）
    "composer-2.5": SnapshotEntry(0.5e-6, 2.5e-6, 0.5e-6, 0.2e-6, nil),
    "composer-2": SnapshotEntry(0.5e-6, 2.5e-6, 0.5e-6, 0.2e-6, nil),
    "composer-1.5": SnapshotEntry(3.5e-6, 17.5e-6, 3.5e-6, 0.35e-6, nil),
    "composer-1": SnapshotEntry(1.25e-6, 10e-6, 1.25e-6, 0.125e-6, nil),
]

/// grok-4.6 高价位档：prompt（input + cacheRead）跨过 20 万 token 后全量按高档计
let GROK_4_6_PROMPT_TOKEN_THRESHOLD: Double = 200_000
let GROK_4_6_HIGH_PROMPT_COSTS = ModelCosts(input: 4e-6, output: 12e-6, cacheWrite: nil, cacheRead: 1e-6)

/// 用户侧别名映射文件：{ "内部名": "价目名" }
func loadModelAliases() -> [String: String] {
    guard let parsed = parseJSONFile(((homePath() as NSString).appendingPathComponent(".config/wattson")) + "/model-aliases.json"),
          let obj = parsed.obj else { return [:] }
    var out: [String: String] = [:]
    for (k, v) in obj { if let s = v.str { out[k] = s } }
    return out
}

// MARK: - 远程价目（LiteLLM 官方快照，24h 本地缓存）

private let remoteLock = NSLock()
private var remoteSnapshot: [String: SnapshotEntry] = [:]

let LITELLM_PRICING_URL = "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
let PRICING_CACHE_TTL: TimeInterval = 24 * 3600

private func pricingCachePath() -> String {
    ((homePath() as NSString).appendingPathComponent("wattson/cache")) + "/litellm-prices.json"
}

/// 装载/刷新 LiteLLM 价目：缓存 24h 内直接用，否则拉取远端并回写缓存。
/// 返回 true = 装载了新快照（调用方可触发一次重算）。
@discardableResult
public func refreshRemotePricing() async -> Bool {
    let cacheFile = pricingCachePath()
    if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile),
       let mtime = attrs[.modificationDate] as? Date,
       Date().timeIntervalSince(mtime) < PRICING_CACHE_TTL,
       !remoteSnapshotIsEmpty() {
        return false  // 缓存新鲜且已装载
    }
    // 先试装载磁盘缓存（远端不可达时的离线兜底）
    if remoteSnapshotIsEmpty(), let data = FileManager.default.contents(atPath: cacheFile) {
        installRemoteSnapshot(data)
    }
    guard let url = URL(string: LITELLM_PRICING_URL),
          let (data, resp) = try? await URLSession.shared.data(from: url),
          (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else {
        return false
    }
    try? FileManager.default.createDirectory(atPath: (cacheFile as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: cacheFile))
    return installRemoteSnapshot(data)
}

private func remoteSnapshotIsEmpty() -> Bool {
    remoteLock.lock(); defer { remoteLock.unlock() }
    return remoteSnapshot.isEmpty
}

/// 解析 LiteLLM 快照（键形如 "gemini/gemini-2.5-pro"，取末段匹配）；返回是否有可用条目
@discardableResult
private func installRemoteSnapshot(_ data: Data) -> Bool {
    guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
    var out: [String: SnapshotEntry] = [:]
    for (rawKey, raw) in parsed {
        // LiteLLM 键可带 provider 前缀（openai/、gemini/…），取最后一段做模型名
        let key = rawKey.split(separator: "/").last.map(String.init) ?? rawKey
        guard let obj = raw as? [String: Any] else { continue }
        guard let input = obj["input_cost_per_token"] as? Double,
              let output = obj["output_cost_per_token"] as? Double, input > 0 || output > 0 else { continue }
        let cacheWrite = obj["cache_creation_input_token_cost"] as? Double
        let cacheRead = obj["cache_read_input_token_cost"] as? Double
        let fast = (obj["provider_specific_entry"] as? [String: Any])?["fast"] as? Double
        out[key.lowercased()] = SnapshotEntry(input, output, cacheWrite, cacheRead, fast)
    }
    guard !out.isEmpty else { return false }
    remoteLock.lock()
    remoteSnapshot = out
    remoteLock.unlock()
    return true
}

/// 价目查询：精确 → 别名 → 去日期后缀 → 最长前缀（按 - 边界）
public func getModelCosts(_ model: String) -> ModelCosts? {
    resolvePricing(model).map(entryCosts)
}

func entryCosts(_ e: SnapshotEntry) -> ModelCosts {
    ModelCosts(input: e.input, output: e.output, cacheWrite: e.cacheWrite,
               cacheRead: e.cacheRead, fast: e.fast)
}

/// 该模型是否公布了明确的缓存写入单价。
/// false = 缓存写价由 1.25×输入兜底推导，不代表供应商真的收这笔钱——codex 因此
/// 只在 true 时才把 token 从普通输入划到缓存写桶（否则会凭空造出附加费）。
public func cacheWriteCostIsExplicit(_ model: String) -> Bool {
    resolvePricing(model)?.cacheWrite != nil
}

private func resolvePricing(_ model: String) -> SnapshotEntry? {
    func lookup(_ m: String) -> SnapshotEntry? {
        if let e = PRICING_SNAPSHOT[m] { return e }
        let lower = m.lowercased()
        if let e = PRICING_SNAPSHOT[lower] { return e }
        return nil
    }
    if let e = lookup(model) { return e }
    // LiteLLM 远程快照（精确匹配；lowercased 键）
    remoteLock.lock()
    let remoteHit = remoteSnapshot[model.lowercased()]
    remoteLock.unlock()
    if let e = remoteHit { return e }
    // 别名（静态文件每次读取成本可接受：调用频率 = 每次 refresh 每行一次；
    // 行级重估时同一快照已带 costUSD 不会再进来）
    let aliases = loadModelAliases()
    if let target = aliases[model], let e = lookup(target) { return e }
    // 去日期后缀（gpt-5.2-20260101 → gpt-5.2）：先内嵌再远程
    var base = model.lowercased()
    if let r = base.range(of: #"-[0-9]{6,8}$"#, options: .regularExpression) {
        base = String(base[..<r.lowerBound])
        if let e = lookup(base) { return e }
        remoteLock.lock()
        let remoteBase = remoteSnapshot[base]
        remoteLock.unlock()
        if let e = remoteBase { return e }
    }
    // 最长前缀（按 - 边界）：glm-5.2-thinking → glm-5.2
    var candidates: [String] = []
    var idx = base.startIndex
    while let r = base[idx...].range(of: "-") {
        idx = r.lowerBound
        candidates.append(String(base[..<idx]))
        idx = base.index(after: idx)
        if idx >= base.endIndex { break }
    }
    for c in candidates.reversed() {
        if let e = PRICING_SNAPSHOT[c] { return e }
    }
    remoteLock.lock()
    let remoteCandidates = candidates.compactMap { remoteSnapshot[$0] }
    remoteLock.unlock()
    return remoteCandidates.first
}


func tieredCostsFor(_ model: String, _ costs: ModelCosts, _ promptTokens: Double) -> ModelCosts {
    if model.lowercased().hasPrefix("grok-4.6"), promptTokens >= GROK_4_6_PROMPT_TOKEN_THRESHOLD {
        return GROK_4_6_HIGH_PROMPT_COSTS
    }
    return costs
}

/// 单次调用成本（USD）。未收录模型返回 0 —— 0 是合法成本，不是缺失。
public func calculateCost(model: String, inputTokens: Double, outputTokens: Double,
                          cacheCreationTokens: Double, cacheReadTokens: Double,
                          webSearchRequests: Double = 0, speed: String = "standard",
                          oneHourCacheCreationTokens: Double = 0) -> Double {
    guard let costs = getModelCosts(model) else { return 0 }
    let safe = { (n: Double) -> Double in n.isFinite && n > 0 ? n : 0 }
    let safeOneHour = safe(oneHourCacheCreationTokens)
    let safeCacheCreation = max(safe(cacheCreationTokens), safeOneHour)
    let safeFiveMinute = max(0, safeCacheCreation - safeOneHour)
    let promptTokens = safe(inputTokens) + safe(cacheReadTokens)
    let tiered = tieredCostsFor(model, costs, promptTokens)
    let multiplier = speed == "fast" ? tiered.fastMultiplier : 1
    // 负数/非有限输入一律钳 0：损坏数据不得从总成本里偷偷减钱
    return multiplier * (
        safe(inputTokens) * tiered.inputCostPerToken
            + safe(outputTokens) * tiered.outputCostPerToken
            + safeFiveMinute * tiered.cacheWriteCostPerToken
            + safeOneHour * tiered.cacheWriteCostPerToken * 1.6
            + safe(cacheReadTokens) * tiered.cacheReadCostPerToken
            + safe(webSearchRequests) * tiered.webSearchCostPerRequest)
}
