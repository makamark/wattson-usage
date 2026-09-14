// Core/SessionCache.swift — 会话缓存内存模型（解析产物 → 聚合输入）。
// 原生实现的缓存形态：providers → files → turns → calls 四层，
// 字段口径与用量行映射（aggregate.rowsFromCache）保持一致。
import Foundation

public struct CachedUsage: Sendable, Equatable {
    public var inputTokens: Double
    public var outputTokens: Double
    public var cacheCreationInputTokens: Double
    public var cacheReadInputTokens: Double
    public var reasoningTokens: Double
    public var webSearchRequests: Double
    /// 部分提供商区分 1 小时长缓存写入（更高单价）
    public var cacheCreationOneHourTokens: Double

    public init(inputTokens: Double = 0, outputTokens: Double = 0,
                cacheCreationInputTokens: Double = 0, cacheReadInputTokens: Double = 0,
                reasoningTokens: Double = 0, webSearchRequests: Double = 0,
                cacheCreationOneHourTokens: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.reasoningTokens = reasoningTokens
        self.webSearchRequests = webSearchRequests
        self.cacheCreationOneHourTokens = cacheCreationOneHourTokens
    }
}

public struct CachedCall: Sendable, Equatable {
    /// 工具名覆盖（缺省用所在 provider 分区名）
    public var provider: String?
    public var model: String?
    public var usage: CachedUsage?
    /// 已存成本；nil = 解析时未定价，聚合层按价目表重估并标记估算
    public var costUSD: Double?
    /// "standard" | "fast"
    public var speed: String?
    public var timestamp: String
    public var project: String?
    public var isEstimated: Bool?
    public var costIsEstimated: Bool?

    public init(provider: String? = nil, model: String? = nil, usage: CachedUsage? = nil,
                costUSD: Double? = nil, speed: String? = nil, timestamp: String,
                project: String? = nil, isEstimated: Bool? = nil, costIsEstimated: Bool? = nil) {
        self.provider = provider
        self.model = model
        self.usage = usage
        self.costUSD = costUSD
        self.speed = speed
        self.timestamp = timestamp
        self.project = project
        self.isEstimated = isEstimated
        self.costIsEstimated = costIsEstimated
    }
}

public struct CachedTurn: Sendable, Equatable {
    public var timestamp: String
    public var sessionId: String?
    public var calls: [CachedCall]

    public init(timestamp: String, sessionId: String? = nil, calls: [CachedCall] = []) {
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.calls = calls
    }
}

public struct FileFingerprint: Sendable, Equatable {
    public var dev: Double
    public var ino: Double
    public var mtimeMs: Double
    public var sizeBytes: Double

    public init(dev: Double = 0, ino: Double = 0, mtimeMs: Double = 0, sizeBytes: Double = 0) {
        self.dev = dev
        self.ino = ino
        self.mtimeMs = mtimeMs
        self.sizeBytes = sizeBytes
    }
}

public struct CachedFile: Sendable, Equatable {
    public var fingerprint: FileFingerprint?
    public var turns: [CachedTurn]

    public init(fingerprint: FileFingerprint? = nil, turns: [CachedTurn] = []) {
        self.fingerprint = fingerprint
        self.turns = turns
    }
}

public struct ProviderSection: Sendable, Equatable {
    public var envFingerprint: String?
    public var files: [String: CachedFile]

    public init(envFingerprint: String? = nil, files: [String: CachedFile] = [:]) {
        self.envFingerprint = envFingerprint
        self.files = files
    }
}

public struct SessionCache: Sendable, Equatable {
    public var version: Double
    public var complete: Bool
    public var providers: [String: ProviderSection]

    public init(version: Double = 9, complete: Bool = true, providers: [String: ProviderSection] = [:]) {
        self.version = version
        self.complete = complete
        self.providers = providers
    }
}
