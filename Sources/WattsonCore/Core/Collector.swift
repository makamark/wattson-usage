// Core/Collector.swift — 驱动解析管线产出 Snapshot（rows + 新鲜度拆分）。
// parseAll / loadCache 可注入（测试缝）；生产路径用 SessionScanner 全量扫描 +
// 内存缓存。任何刷新失败都落进 snapshot.errors，旧行原样保留；失败轮只推进
// fetchedAt（尝试时间），lastSuccessAt 保留上一个成功值。
import Foundation

public struct Snapshot: Sendable, Equatable {
    public var rows: [UsageRow]
    public var fetchedAt: Double
    /// 最近一次「成功」采集时间；失败轮保留旧值
    public var lastSuccessAt: Double?
    public var errors: [String]
    public var refreshing: Bool
    /// 聚合响应体缓存以「行数组整体替换」为失效边界：每次 refresh 产生新实例身份
    public let instanceID = UUID()

    public init(rows: [UsageRow] = [], fetchedAt: Double = 0, lastSuccessAt: Double? = nil,
                errors: [String] = [], refreshing: Bool = false) {
        self.rows = rows
        self.fetchedAt = fetchedAt
        self.lastSuccessAt = lastSuccessAt
        self.errors = errors
        self.refreshing = refreshing
    }
}

func errMsg(_ err: Error) -> String { errText(err) }

public final class Collector: @unchecked Sendable {
    public let devices: [DeviceRoot]
    public let localHost: String
    private let lock = NSLock()
    private var state: Snapshot
    private var inflight: Task<Snapshot, Never>?
    private let parseAll: @Sendable () async throws -> Void
    private let loadCacheOpt: @Sendable () async throws -> SessionCache

    public init(devices: [DeviceRoot]? = nil, localHost: String? = nil,
                parseAll: (@Sendable () async throws -> Void)? = nil,
                loadCache: (@Sendable () async throws -> SessionCache)? = nil) {
        self.devices = devices ?? loadDeviceRoots()
        self.localHost = localHost ?? shortHostname()
        self.state = Snapshot()
        self.parseAll = parseAll ?? { try await parseAllSessions() }
        self.loadCacheOpt = loadCache ?? { try loadSessionCache() }
    }

    public var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    /// 并发/排队语义：进行中的刷新不重复触发，后来者共享同一轮结果；
    /// 刷新结束后再来的调用开启新一轮。
    public func refresh() async -> Snapshot {
        lock.lock()
        if let t = inflight {
            lock.unlock()
            return await t.value
        }
        var start = state
        start.refreshing = true
        state = start
        let task = Task<Snapshot, Never> { await self.performRefresh(start) }
        inflight = task
        lock.unlock()
        let v = await task.value
        return v
    }

    private func performRefresh(_ start: Snapshot) async -> Snapshot {
        var errors: [String] = []
        do {
            try await parseAll()
        } catch {
            errors.append("parseAllSessions: \(errMsg(error))")
        }
        var rows = start.rows
        if errors.isEmpty {
            do {
                let cache = try await loadCacheOpt()
                rows = rowsFromCache(cache, devices, localHost)
            } catch {
                errors.append("loadCache: \(errMsg(error))")
            }
        }
        let now = Date.nowMs()
        let settled = Snapshot(
            rows: rows,
            fetchedAt: now,
            lastSuccessAt: errors.isEmpty ? now : start.lastSuccessAt,
            errors: errors,
            refreshing: false)
        lock.lock()
        self.state = settled
        self.inflight = nil
        lock.unlock()
        return settled
    }
}
