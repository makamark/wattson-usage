// Core/Aggregate.swift — 会话缓存之上的纯聚合层。
// token 总量口径与成本计费口径保持一致：reasoning-in-output 提供商
// （claude/codex/copilot）的 reasoningTokens 是 outputTokens 的子集，
// rowTokens 与成本走同一套 billableOutputTokens 去重逻辑，两套数字不再打架。
import Foundation

public struct UsageRow: Sendable, Equatable {
    public var host: String
    public var tool: String
    public var model: String
    public var ts: Double
    public var project: String
    public var tin: Double
    public var tout: Double
    public var tcacheRead: Double
    public var tcacheWrite: Double
    public var treason: Double
    public var cost: Double?
    public var costEstimated: Bool

    public init(host: String, tool: String, model: String, ts: Double, project: String,
                tin: Double, tout: Double, tcacheRead: Double, tcacheWrite: Double,
                treason: Double, cost: Double?, costEstimated: Bool) {
        self.host = host
        self.tool = tool
        self.model = model
        self.ts = ts
        self.project = project
        self.tin = tin
        self.tout = tout
        self.tcacheRead = tcacheRead
        self.tcacheWrite = tcacheWrite
        self.treason = treason
        self.cost = cost
        self.costEstimated = costEstimated
    }
}

/// total = 不分组的单一系列（主图「总计」视图用）
public typealias Group = String
public typealias Bucket = String
public typealias Metric = String

public struct RowFilter: Sendable, Equatable {
    public var rangeMs: Double?
    public var hosts: [String]
    public var tools: [String]
    public var models: [String]
    public var projects: [String]

    public init(rangeMs: Double? = nil, hosts: [String] = [], tools: [String] = [],
                models: [String] = [], projects: [String] = []) {
        self.rangeMs = rangeMs
        self.hosts = hosts
        self.tools = tools
        self.models = models
        self.projects = projects
    }
}

public struct SeriesResult: Sendable, Equatable {
    public var times: [Double]
    public var series: [String: [Double?]]
    public var unit: String
}

let DAY: Double = 24 * 3600 * 1000

func aggNum(_ v: JSON?) -> Double {
    guard let n = v?.num, n.isFinite else { return 0 }
    return n
}

public func rowsFromCache(_ cache: SessionCache, _ devices: [DeviceRoot], _ localHost: String) -> [UsageRow] {
    var rows: [UsageRow] = []
    for (provider, section) in cache.providers {
        for (path, file) in section.files {
            let host = hostForSourcePath(path, roots: devices, localHost: localHost)
            for turn in file.turns {
                for call in turn.calls {
                    let usage = call.usage ?? CachedUsage()
                    guard let ts = parseJSDate(call.timestamp) else { continue }
                    let tin = usage.inputTokens, tout = usage.outputTokens
                    let tcacheRead = usage.cacheReadInputTokens
                    let tcacheWrite = usage.cacheCreationInputTokens
                    let treason = usage.reasoningTokens
                    let tool = call.provider ?? provider
                    let model = call.model ?? "unknown"
                    let storedCost = call.costUSD
                    // 未存 costUSD 的调用（原生解析器对未定价模型不落值）按
                    // billableOutputTokens + calculateCost 重估——与读取口径一致；
                    // calculateCost 对未收录模型返回 0，0 是合法成本，照实流转。
                    let cost = storedCost ?? calculateCost(
                        model: model, inputTokens: tin,
                        outputTokens: billableOutputTokens(provider: tool, outputTokens: tout, reasoningTokens: treason),
                        cacheCreationTokens: tcacheWrite, cacheReadTokens: tcacheRead,
                        webSearchRequests: usage.webSearchRequests,
                        speed: call.speed == "fast" ? "fast" : "standard",
                        oneHourCacheCreationTokens: usage.cacheCreationOneHourTokens)
                    rows.append(UsageRow(
                        host: host, tool: tool, model: model, ts: ts,
                        project: (call.project?.isEmpty == false) ? call.project! : "unknown",
                        tin: tin, tout: tout, tcacheRead: tcacheRead, tcacheWrite: tcacheWrite,
                        treason: treason, cost: cost,
                        // 重估行（无存储成本）按同一约定标为估算；isEstimated /
                        // costIsEstimated 两种拼写都接受
                        costEstimated: call.isEstimated == true || call.costIsEstimated == true || storedCost == nil))
                }
            }
        }
    }
    return rows
}

public func rowTokens(_ r: UsageRow) -> Double {
    r.tin + r.tcacheRead + r.tcacheWrite
        + billableOutputTokens(provider: r.tool, outputTokens: r.tout, reasoningTokens: r.treason)
}

/// 统一筛选：range + 维度值集合（空集合 = 不过滤）。所有 /api 聚合入口先过这一层，
/// 保证「点选设备/工具」和时间范围在看板各区块语义一致。
public func filterRows(_ rows: [UsageRow], _ f: RowFilter, _ now: Double) -> [UsageRow] {
    let cutoff = f.rangeMs.map { now - $0 }
    func match(_ list: [String], _ v: String) -> Bool { list.isEmpty || list.contains(v) }
    return rows.filter { r in
        (cutoff == nil || r.ts >= cutoff!) &&
        match(f.hosts, r.host) && match(f.tools, r.tool) &&
        match(f.models, r.model) && match(f.projects, r.project)
    }
}

func groupValue(_ r: UsageRow, _ group: Group) -> String {
    if group == "total" { return "总计" }
    switch group {
    case "host": return r.host
    case "tool": return r.tool
    case "model": return r.model
    default: return r.project
    }
}

struct SeriesCell {
    var sum: Double = 0
    var hasValue = false
}

public func series(_ rows: [UsageRow], bucket: Bucket, group: Group, rangeMs: Double?,
                   metric: Metric, now: Double, maxSeries: Int? = nil, maxBuckets: Int? = nil) -> SeriesResult {
    var filtered = rows
    if let rangeMs, rangeMs != 0 {
        filtered = filtered.filter { $0.ts >= now - rangeMs }
    }
    let unit = bucket == "day" ? DAY : 3600 * 1000
    // 单循环求 min/max：避免大数组上的多次遍历
    var minTs = Double.infinity, maxTs = -Double.infinity
    for r in filtered {
        if r.ts < minTs { minTs = r.ts }
        if r.ts > maxTs { maxTs = r.ts }
    }
    let start = minTs != .infinity ? bucketStart(minTs, bucket) : bucketStart(now, bucket)
    let end = bucketStart(max(now, maxTs != -.infinity ? maxTs : 0), bucket)
    // 时间网格按「对齐下一个本地桶起点」推进而不是固定 epoch 步长：跨 DST 时本地日
    // 是 23h/25h，固定步长会漂离行实际归属的桶起点。raw 每轮 +unit，直到对齐取得进展。
    var times: [Double] = []
    var t = start
    while t <= end {
        times.append(t)
        var raw = t + unit
        while bucketStart(raw, bucket) <= t { raw += unit }
        t = bucketStart(raw, bucket)
    }
    // 时间桶上限：只保留最近的 maxBuckets 个桶，窗口外的行不参与分组（避免其分组键挤占 Top-N）
    if let maxBuckets, times.count > maxBuckets {
        times = Array(times.suffix(maxBuckets))
        let floor = times[0]
        filtered = filtered.filter { bucketStart($0.ts, bucket) >= floor }
    }
    let index = Dictionary(uniqueKeysWithValues: times.enumerated().map { ($1, $0) })
    // 分组键来自数据（host/tool/model/project 名），Swift 字典天然无原型继承问题
    var groupKeys = Array(Set(filtered.map { groupValue($0, group) })).sorted()
    var acc: [String: [SeriesCell]] = [:]
    for g in groupKeys { acc[g] = times.map { _ in SeriesCell() } }
    for r in filtered {
        guard let idx = index[bucketStart(r.ts, bucket)] else { continue }
        let key = groupValue(r, group)
        if metric == "calls" {
            acc[key]![idx].sum += 1
        } else if metric == "cost" {
            if let cost = r.cost {
                acc[key]![idx].sum += cost
                acc[key]![idx].hasValue = true
            }
        } else {
            acc[key]![idx].sum += rowTokens(r)
        }
    }
    // Top-N：分组数超上限时按全期总量保留前 N-1 名，其余合并为「其他」，
    // 防止高基数维度（如 project）撑爆图例与响应体
    var outKeys = groupKeys
    let mergeTarget = groupKeys.contains("其他") ? "其他*" : "其他"
    if let maxSeries, groupKeys.count > maxSeries {
        func totalOf(_ g: String) -> Double {
            acc[g]!.reduce(0) { s, c in
                s + (metric == "cost" && !c.hasValue ? 0 : c.sum)
            }
        }
        let keep = groupKeys
            .sorted { a, b in
                let (ta, tb) = (totalOf(a), totalOf(b))
                return ta != tb ? ta > tb : a < b
            }
            .prefix(maxSeries - 1)
        let keepSet = Set(keep)
        let rest = groupKeys.filter { !keepSet.contains($0) }
        acc[mergeTarget] = times.map { _ in SeriesCell() }
        for g in rest {
            var from = acc[g]!
            var to = acc[mergeTarget]!
            for i in 0..<to.count {
                if metric == "cost" && !from[i].hasValue { continue }
                to[i].sum += from[i].sum
                to[i].hasValue = to[i].hasValue || from[i].hasValue
            }
            acc[mergeTarget] = to
        }
        outKeys = Array(keep).sorted()
        if !keepSet.contains(mergeTarget) { outKeys.append(mergeTarget) }
    }
    var out: [String: [Double?]] = [:]
    for g in outKeys {
        out[g] = acc[g]!.map { metric == "cost" ? ($0.hasValue ? $0.sum : nil) : $0.sum }
    }
    _ = groupKeys.count // groupKeys 仍被用于 Top-N 判定，避免误删
    return SeriesResult(times: times, series: out,
                        unit: metric == "cost" ? "USD" : metric == "calls" ? "calls" : "tokens")
}

public struct OverviewEntry: Sendable, Equatable {
    public var tokens: Double
    public var cost: Double?
    public var calls: Double
}

public struct OverviewResult: Sendable, Equatable {
    public var totalTokens: Double
    public var totalCost: Double?
    public var calls: Double
    public var cacheHitRate: Double?
    public var activeDays: Int
    public var byHost: [String: OverviewEntry]
    public var byTool: [String: OverviewEntry]
    public var estimatedCost: Double
}

public func overview(_ rows: [UsageRow]) -> OverviewResult {
    var totalTokens: Double = 0, calls: Double = 0, cacheRead: Double = 0, freshInput: Double = 0
    var cost: Double = 0, costSeen = false, estimatedCost: Double = 0
    var days = Set<String>()
    var byHost: [String: OverviewEntry] = [:]
    var byTool: [String: OverviewEntry] = [:]
    func bump(_ map: inout [String: OverviewEntry], _ key: String, _ r: UsageRow) {
        var e = map[key] ?? OverviewEntry(tokens: 0, cost: nil, calls: 0)
        e.tokens += rowTokens(r)
        e.calls += 1
        if let c = r.cost { e.cost = (e.cost ?? 0) + c }
        map[key] = e
    }
    for r in rows {
        totalTokens += rowTokens(r); calls += 1
        cacheRead += r.tcacheRead; freshInput += r.tin
        if let c = r.cost {
            cost += c; costSeen = true
            // 估算成本单独透出：未存储成本 / 标记 estimated 的行不能与实价混为一谈
            if r.costEstimated { estimatedCost += c }
        }
        days.insert(dayKey(r.ts))
        bump(&byHost, r.host, r); bump(&byTool, r.tool, r)
    }
    return OverviewResult(
        totalTokens: totalTokens,
        totalCost: costSeen ? cost : nil,
        calls: calls,
        cacheHitRate: freshInput + cacheRead > 0 ? cacheRead / (freshInput + cacheRead) : nil,
        activeDays: days.count,
        byHost: byHost, byTool: byTool,
        estimatedCost: estimatedCost)
}

public struct MatrixResult: Sendable, Equatable {
    public var rowKeys: [String]
    public var colKeys: [String]
    public var values: [[Double?]]
}

public func matrix(_ rows: [UsageRow], _ rowKey: Group, colKey: String = "model") -> MatrixResult {
    func col(_ r: UsageRow) -> String { colKey == "model" ? r.model : r.model }
    let rowKeys = Array(Set(rows.map { groupValue($0, rowKey) })).sorted()
    let colKeys = Array(Set(rows.map { col($0) })).sorted()
    let ri = Dictionary(uniqueKeysWithValues: rowKeys.enumerated().map { ($1, $0) })
    let ci = Dictionary(uniqueKeysWithValues: colKeys.enumerated().map { ($1, $0) })
    var values: [[Double?]] = rowKeys.map { _ in colKeys.map { _ in nil } }
    for r in rows {
        let i = ri[groupValue(r, rowKey)]!, j = ci[col(r)]!
        values[i][j] = (values[i][j] ?? 0) + rowTokens(r)
    }
    return MatrixResult(rowKeys: rowKeys, colKeys: colKeys, values: values)
}

public struct ModelTableEntry: Sendable, Equatable {
    public var model: String
    public var calls: Double
    public var tokens: Double
    public var tin: Double
    public var tout: Double
    public var treason: Double
    public var tcacheRead: Double
    public var tcacheWrite: Double
    public var cost: Double?
}

public func modelTable(_ rows: [UsageRow]) -> [ModelTableEntry] {
    // tokens = 每行按其所属工具口径（rowTokens）累加：同一模型可能来自多个工具
    //（reasoning 口径不同），必须在行级去重后再合并，不能事后用单一工具重算
    var map: [String: ModelTableEntry] = [:]
    for r in rows {
        var e = map[r.model] ?? ModelTableEntry(model: r.model, calls: 0, tokens: 0, tin: 0,
                                                tout: 0, treason: 0, tcacheRead: 0, tcacheWrite: 0, cost: nil)
        e.calls += 1
        e.tokens += rowTokens(r)
        e.tin += r.tin; e.tout += r.tout; e.treason += r.treason
        e.tcacheRead += r.tcacheRead; e.tcacheWrite += r.tcacheWrite
        if let c = r.cost { e.cost = (e.cost ?? 0) + c }
        map[r.model] = e
    }
    // 排序键 = 展示口径的 token 总量，与「服务端已按 token 总量降序」一致
    return map.values.sorted { $0.tokens > $1.tokens }
}
