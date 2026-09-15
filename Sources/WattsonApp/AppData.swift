// AppData.swift — 看板/小窗共享的全局筛选与进程内聚合数据辅助。
// 口径对应 web/src/state.ts + api.ts：任何区块共享同一份 filters，
// 先 filterRows 再聚合；compare=previous 对上一等长窗口重跑同一聚合。
import Foundation
import WattsonCore

// MARK: - 筛选状态（state.ts Filters）

enum RangeOption: String, CaseIterable, Identifiable {
    case today
    case h24 = "24h"
    case d7 = "7d"
    case d30 = "30d"
    case all

    var id: String { rawValue }

    /// 动态窗口长度（ms）；today 为本地零点至今；all = 不过滤
    var ms: Double? {
        switch self {
        case .today: return Date.nowMs() - localMidnight(Date.nowMs())
        case .h24: return 24 * 3600 * 1000
        case .d7: return 7 * 24 * 3600 * 1000
        case .d30: return 30 * 24 * 3600 * 1000
        case .all: return nil
        }
    }

    var label: String {
        switch self {
        case .today: return "今日"
        case .h24: return "24 小时"
        case .d7: return "7 天"
        case .d30: return "30 天"
        case .all: return "全部"
        }
    }

    /// popup 的大标题（popup.html RANGE_TITLES）
    var popupTitle: String {
        switch self {
        case .today: return "今日"
        case .h24: return "近 24 小时"
        case .d7: return "近 7 天"
        case .d30: return "近 30 天"
        case .all: return "全部"
        }
    }

    /// 24h/今日 用小时桶（mainchart.ts hourly）
    var isHourly: Bool { self == .today || self == .h24 }
}

enum MetricOption: String, CaseIterable, Identifiable {
    case tokens, cost, calls
    var id: String { rawValue }
    var label: String {
        switch self {
        case .tokens: return "Token"
        case .cost: return "成本"
        case .calls: return "调用"
        }
    }
}

enum GroupOption: String, CaseIterable, Identifiable {
    case total, model, host, tool
    var id: String { rawValue }
    var label: String {
        switch self {
        case .total: return "总计"
        case .model: return "按模型"
        case .host: return "按设备"
        case .tool: return "按工具"
        }
    }
}

struct DashboardFilters: Equatable {
    var range: RangeOption = .d30
    var hosts: [String] = []
    var tools: [String] = []
    var models: [String] = []
    var projects: [String] = []
    var metric: MetricOption = .tokens
    var group: GroupOption = .model

    var hasDrilldown: Bool { !hosts.isEmpty || !tools.isEmpty }
}

// MARK: - KPI 环比（kpi.ts deltaHtml 口径）

struct KpiDelta: Equatable {
    let up: Bool
    let text: String
}

func kpiValue(_ key: String, _ o: OverviewResult) -> Double? {
    switch key {
    case "totalTokens": return o.totalTokens
    case "totalCost": return o.totalCost
    case "calls": return o.calls
    case "cacheHitRate": return o.cacheHitRate
    case "activeDays": return Double(o.activeDays)
    default: return nil
    }
}

func kpiDelta(_ key: String, _ cur: OverviewResult, _ prev: OverviewResult?) -> KpiDelta? {
    guard let prev, let c = kpiValue(key, cur), let p = kpiValue(key, prev) else { return nil }
    if key == "cacheHitRate" {
        let diff = (c - p) * 100
        guard diff.isFinite, abs(diff) >= 0.05 else { return nil }
        return KpiDelta(up: diff > 0, text: String(format: "%@%.1fpp", diff > 0 ? "↑ " : "↓ ", abs(diff)))
    }
    if key == "activeDays" {
        let diff = c - p
        guard diff != 0 else { return nil }
        return KpiDelta(up: diff > 0, text: "\(diff > 0 ? "↑" : "↓") \(Int(abs(diff))) 天")
    }
    guard p > 0 else { return nil }
    let pct = (c - p) / p * 100
    guard pct.isFinite, abs(pct) >= 0.5 else { return nil }
    let num = String(format: (pct > -10 && pct < 10) ? "%.1f" : "%.0f", abs(pct))
    return KpiDelta(up: pct > 0, text: "\(pct > 0 ? "↑" : "↓") \(num)%")
}

// MARK: - 进程内聚合数据（等价于 HTTP /api/* 的进程内调用）

extension AppState {
    func rowFilter(_ f: DashboardFilters, hosts: [String]? = nil, tools: [String]? = nil) -> RowFilter {
        RowFilter(rangeMs: f.range.ms,
                  hosts: hosts ?? f.hosts,
                  tools: tools ?? f.tools,
                  models: f.models,
                  projects: f.projects)
    }

    /// /api/overview?compare=previous 的进程内等价（含分面 + allTime）
    func overviewData(_ f: DashboardFilters) -> (main: OverviewResult, prev: OverviewResult?,
                                                 allTime: OverviewResult,
                                                 facetHost: [(String, OverviewEntry)],
                                                 facetTool: [(String, OverviewEntry)]) {
        let now = Date.nowMs()
        let rows = snapshot.rows
        let scoped = overview(filterRows(rows, rowFilter(f), now))
        // 分面口径：byHost 忽略 hosts 过滤、byTool 忽略 tools 过滤（其余条件生效）
        let facetHost = overview(filterRows(rows, rowFilter(f, hosts: []), now)).byHost
        let facetTool = overview(filterRows(rows, rowFilter(f, tools: []), now)).byTool
        // compare=previous：上一等长窗口 [now-2N, now-N)
        var prev: OverviewResult? = nil
        if let rangeMs = f.range.ms {
            let prevRows = filterRows(rows, rowFilter(f), now - rangeMs).filter { $0.ts < now - rangeMs }
            prev = overview(prevRows)
        }
        return (scoped, prev, overview(rows),
                facetHost.sorted { $0.value.tokens > $1.value.tokens },
                facetTool.sorted { $0.value.tokens > $1.value.tokens })
    }

    /// /api/series 的进程内等价（24h/今日 → hour 桶；Top-12 合并与桶上限在 series() 内）
    func seriesData(_ f: DashboardFilters, group override: GroupOption? = nil) -> SeriesResult {
        let now = Date.nowMs()
        let bucket: Bucket = f.range.isHourly ? "hour" : "day"
        return series(filterRows(snapshot.rows, rowFilter(f), now),
                      bucket: bucket, group: (override ?? f.group).rawValue,
                      rangeMs: nil, metric: f.metric.rawValue, now: now,
                      maxSeries: 12, maxBuckets: 400)
    }

    /// /api/matrix 的进程内等价（有钻取时行切到 model）
    func matrixData(_ f: DashboardFilters) -> (rowsKey: String, result: MatrixResult) {
        let rowsKey = f.hasDrilldown ? "model" : "host"
        let now = Date.nowMs()
        return (rowsKey, matrix(filterRows(snapshot.rows, rowFilter(f), now), rowsKey))
    }

    /// /api/models 的进程内等价
    func modelsData(_ f: DashboardFilters) -> [ModelTableEntry] {
        modelTable(filterRows(snapshot.rows, rowFilter(f), Date.nowMs()))
    }

    /// popup 明细（breakdown）：过滤零值、按 token 降序 + 合计
    func breakdown(_ map: [String: OverviewEntry]) -> [(name: String, tokens: Double, cost: Double?)] {
        map.map { ($0.key, $0.value.tokens, $0.value.cost) }
            .filter { $0.tokens > 0 }
            .sorted { $0.tokens > $1.tokens }
    }
}
