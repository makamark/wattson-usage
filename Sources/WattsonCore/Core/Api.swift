// Core/Api.swift — 纯路由：输入请求 + Snapshot，输出状态码 + JSON 体，无 I/O、
// 无服务器状态，路由表可直接测试（见 ApiTests）。
// 所有聚合路由共享同一套查询条件（range/hosts/tools/models/projects）：先 filterRows
// 再聚合，保证 KPI/主图/矩阵/模型表对「点选钻取 + 时间范围」语义一致；
// 刻意不过滤的口径（overview.allTime）在响应里单独命名，不与主值混用。
import Foundation

public struct ApiRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]

    public init(method: String = "GET", path: String, query: [String: String] = [:]) {
        self.method = method
        self.path = path
        self.query = query
    }

    /// 从 "GET /api/overview?range=7d" 形式的目标串构造
    public init(target: String, method: String = "GET") {
        let parts = target.split(separator: "?", maxSplits: 1).map(String.init)
        var q: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard let k = kv.first.map(Self.decodeComponent) else { continue }
                q[k] = kv.count > 1 ? Self.decodeComponent(kv[1]) : ""
            }
        }
        self.init(method: method, path: parts[0], query: q)
    }

    static func decodeComponent(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}

public typealias ApiResult = (status: Int, body: JSON)

/// 聚合结果按「快照实例 + 查询串」缓存：rows 在每次 refresh 时整体替换，
/// 同一快照内页面一次渲染的多个区块可直接复用，避免每请求全量重扫。
public final class ApiBodyCache: @unchecked Sendable {
    public static let shared = ApiBodyCache()
    private let lock = NSLock()
    private var map: [UUID: [String: JSON]] = [:]

    func get(_ id: UUID, _ key: String) -> JSON? {
        lock.lock(); defer { lock.unlock() }
        return map[id]?[key]
    }

    func put(_ id: UUID, _ key: String, _ body: JSON) {
        lock.lock(); defer { lock.unlock() }
        var m = map[id] ?? [:]
        if m.count >= 200 { m.removeAll() }
        m[key] = body
        map[id] = m
    }
}

// today 为动态窗口（本地零点起）：rangeMs 逐请求计算，不在常量表里
let RANGES: [String: Double?] = [
    "24h": 24 * 3600e3, "7d": 7 * 24 * 3600e3, "30d": 30 * 24 * 3600e3, "all": nil,
]
let BUCKETS: [String] = ["day", "hour"]
let GROUPS: [String] = ["total", "host", "tool", "model", "project"]
let METRICS: [String] = ["tokens", "cost", "calls"]
// 资源边界：分组数超 Top-N 合并为「其他」；时间桶数超上限只保留最近窗口
let MAX_SERIES = 12
let MAX_BUCKETS = 400

/// 解析范围参数为窗口长度（ms）；error 非空 = 400 错误消息
func rangeMsFromQuery(_ rangeRaw: String, now: Double) -> (value: Double?, error: String?) {
    if rangeRaw == "today" {
        return (now - localMidnight(now), nil)
    }
    if let v = RANGES[rangeRaw] { return (v, nil) }
    return (nil, "未知范围: \(rangeRaw)（可选 24h/today/7d/30d/all）")
}

/// 解析统一筛选参数；error 非空为 400 错误消息
func parseFilterQuery(_ req: ApiRequest, _ now: Double) -> (filter: RowFilter?, error: String?) {
    let r = rangeMsFromQuery(req.query["range"] ?? "all", now: now)
    if let m = r.error {
        return (nil, m)
    }
    func csv(_ name: String) -> [String] {
        (req.query[name] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    return (RowFilter(rangeMs: r.value, hosts: csv("hosts"), tools: csv("tools"),
                      models: csv("models"), projects: csv("projects")), nil)
}

func fail(_ error: String) -> ApiResult { (400, .obj(["error": .str(error)])) }

func overviewJSON(_ o: OverviewResult) -> JSON {
    var byHost: [String: JSON] = [:]
    for (k, e) in o.byHost {
        byHost[k] = .obj([
            "tokens": .num(e.tokens),
            "cost": e.cost.map(JSON.num) ?? .null,
            "calls": .num(e.calls),
        ])
    }
    var byTool: [String: JSON] = [:]
    for (k, e) in o.byTool {
        byTool[k] = .obj([
            "tokens": .num(e.tokens),
            "cost": e.cost.map(JSON.num) ?? .null,
            "calls": .num(e.calls),
        ])
    }
    return .obj([
        "totalTokens": .num(o.totalTokens),
        "totalCost": o.totalCost.map(JSON.num) ?? .null,
        "calls": .num(o.calls),
        "cacheHitRate": o.cacheHitRate.map(JSON.num) ?? .null,
        "activeDays": .num(Double(o.activeDays)),
        "byHost": .obj(byHost),
        "byTool": .obj(byTool),
        "estimatedCost": .num(o.estimatedCost),
    ])
}

func kpiPrevJSON(_ o: OverviewResult) -> JSON {
    .obj([
        "totalTokens": .num(o.totalTokens),
        "totalCost": o.totalCost.map(JSON.num) ?? .null,
        "calls": .num(o.calls),
        "cacheHitRate": o.cacheHitRate.map(JSON.num) ?? .null,
        "activeDays": .num(Double(o.activeDays)),
    ])
}

func seriesJSON(_ s: SeriesResult) -> JSON {
    var out: [String: JSON] = [:]
    for (k, v) in s.series {
        out[k] = .arr(v.map { $0.map(JSON.num) ?? .null })
    }
    return .obj([
        "times": .arr(s.times.map(JSON.num)),
        "series": .obj(out),
        "unit": .str(s.unit),
    ])
}

func matrixJSON(_ m: MatrixResult) -> JSON {
    .obj([
        "rowKeys": .arr(m.rowKeys.map(JSON.str)),
        "colKeys": .arr(m.colKeys.map(JSON.str)),
        "values": .arr(m.values.map { row in .arr(row.map { $0.map(JSON.num) ?? .null }) }),
    ])
}

func modelTableJSON(_ t: [ModelTableEntry]) -> JSON {
    .arr(t.map { e in
        .obj([
            "model": .str(e.model),
            "calls": .num(e.calls),
            "tokens": .num(e.tokens),
            "tin": .num(e.tin),
            "tout": .num(e.tout),
            "treason": .num(e.treason),
            "tcacheRead": .num(e.tcacheRead),
            "tcacheWrite": .num(e.tcacheWrite),
            "cost": e.cost.map(JSON.num) ?? .null,
        ])
    })
}

public func handleApi(_ req: ApiRequest, _ snap: Snapshot, _ localHost: String,
                      handshake: [String: JSON]? = nil, plan: QuotaSnapshot? = nil,
                      cache: ApiBodyCache = .shared,
                      now: (() -> Double)? = nil) -> ApiResult {
    let rows = snap.rows
    let path = req.path
    let clock = now ?? { Date.nowMs() }

    func cached(_ compute: () -> JSON) -> ApiResult {
        let key = path + "?" + req.query.sorted { $0.key < $1.key }.map { "\($0)=\($1)" }.joined(separator: "&")
        if let hit = cache.get(snap.instanceID, key) { return (200, hit) }
        let body = compute()
        cache.put(snap.instanceID, key, body)
        return (200, body)
    }

    if path == "/api/overview" {
        let now = clock()
        let pf = parseFilterQuery(req, now)
        if let m = pf.error { return fail(m) }
        let f = pf.filter!
        let compare = req.query["compare"] ?? ""
        if !compare.isEmpty && compare != "previous" {
            return fail("未知 compare: \(compare)（可选 previous）")
        }
        return cached {
                let scoped = overview(filterRows(rows, f, now))
                // 分面口径：byHost 忽略 hosts 过滤、byTool 忽略 tools 过滤（其余条件生效），
                // 让「按设备/按工具」钻取按钮在已选筛选下仍可见可选
                let facetHost = overview(filterRows(rows, RowFilter(rangeMs: f.rangeMs, hosts: [], tools: f.tools, models: f.models, projects: f.projects), now))
                let facetTool = overview(filterRows(rows, RowFilter(rangeMs: f.rangeMs, hosts: f.hosts, tools: [], models: f.models, projects: f.projects), now))
                // compare=previous：对上一等长窗口再跑一次同一聚合（[now-2N, now-N)）
                var prev: JSON = .null
                if compare == "previous", let rangeMs = f.rangeMs {
                    let prevRows = filterRows(rows, f, now - rangeMs).filter { $0.ts < now - rangeMs }
                    prev = kpiPrevJSON(overview(prevRows))
                }
                var body: [String: JSON]
                if case .obj(let o) = overviewJSON(scoped) { body = o } else { body = [:] }
                // 分面替换：响应里的 byHost/byTool 是「忽略本维度过滤」的钻取口径
                if case .obj(let h) = overviewJSON(facetHost)["byHost"] {
                    body["byHost"] = .obj(h)
                }
                if case .obj(let t) = overviewJSON(facetTool)["byTool"] {
                    body["byTool"] = .obj(t)
                }
                // allTime = 每行全量、不过任何滤（刻意全历史的旁注口径，含 estimatedCost）
                body["allTime"] = overviewJSON(overview(rows))
                body["prev"] = prev
                body["fetchedAt"] = .num(snap.fetchedAt)
                body["lastSuccessAt"] = snap.lastSuccessAt.map(JSON.num) ?? .null
                body["errors"] = .arr(snap.errors.map(JSON.str))
                return .obj(body)
            }
    }
    if path == "/api/series" {
        let bucket = req.query["bucket"] ?? "day"
        if !BUCKETS.contains(bucket) { return fail("未知 bucket: \(bucket)（可选 day/hour）") }
        let group = req.query["group"] ?? "model"
        if !GROUPS.contains(group) { return fail("未知 group: \(group)（可选 total/host/tool/model/project）") }
        let metric = req.query["metric"] ?? "tokens"
        if !METRICS.contains(metric) { return fail("未知 metric: \(metric)（可选 tokens/cost/calls）") }
        let now = clock()
        let pf = parseFilterQuery(req, now)
        if let m = pf.error { return fail(m) }
        let f = pf.filter!
        return cached {
            seriesJSON(series(filterRows(rows, f, now), bucket: bucket, group: group,
                              rangeMs: nil, metric: metric, now: now,
                              maxSeries: MAX_SERIES, maxBuckets: MAX_BUCKETS))
        }
    }
    if path == "/api/matrix" {
        let rowKey = req.query["rows"] ?? "host"
        if !GROUPS.contains(rowKey) { return fail("未知 rows: \(rowKey)（可选 total/host/tool/model/project）") }
        let now = clock()
        let pf = parseFilterQuery(req, now)
        if let m = pf.error { return fail(m) }
        let f = pf.filter!
        return cached {
            matrixJSON(matrix(filterRows(rows, f, now), rowKey))
        }
    }
    if path == "/api/models" {
        let now = clock()
        let pf = parseFilterQuery(req, now)
        if let m = pf.error { return fail(m) }
        let f = pf.filter!
        return cached { modelTableJSON(modelTable(filterRows(rows, f, now))) }
    }
    if path == "/api/plan" {
        // 订阅账号额度，入口进程后台轮询注入。凭据永不出服务端。未初始化时给空 accounts。
        return (200, plan.map(quotaSnapshotJSON) ?? .obj(["accounts": .arr([])]))
    }
    if path == "/api/status" {
        var body: [String: JSON] = [
            "localHost": .str(localHost),
            "fetchedAt": .num(snap.fetchedAt),
            "lastSuccessAt": snap.lastSuccessAt.map(JSON.num) ?? .null,
            "refreshing": .bool(snap.refreshing),
            "errors": .arr(snap.errors.map(JSON.str)),
            "recordCount": .num(Double(rows.count)),
        ]
        for (k, v) in handshake ?? [:] { body[k] = v }
        return (200, .obj(body))
    }
    return (404, .obj(["error": .str("not found")]))
}
