// ApiTests.swift — server/tests/api.test.ts 的移植：handleApi 纯路由表。
import XCTest
@testable import WattsonCore

final class ApiTests: XCTestCase {
    private let NOW = Date.nowMs()

    private func makeSnap(rows: [UsageRow]? = nil) -> Snapshot {
        Snapshot(rows: rows ?? [
            UsageRow(host: "macair", tool: "zcode", model: "glm-5.2", ts: NOW - 1 * HOUR, project: "p",
                     tin: 10, tout: 5, tcacheRead: 100, tcacheWrite: 0, treason: 1, cost: 0.5, costEstimated: false),
            UsageRow(host: "macpro", tool: "codex", model: "gpt-5.2", ts: NOW - 2 * DAY, project: "q",
                     tin: 1, tout: 2, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: nil, costEstimated: true),
            UsageRow(host: "macpro", tool: "codex", model: "gpt-5.2", ts: NOW - 40 * DAY, project: "q",
                     tin: 7, tout: 7, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 9, costEstimated: false),
        ], fetchedAt: 1234, lastSuccessAt: 1200, errors: ["earlier refresh failed"])
    }

    private func get(_ target: String, _ snap: Snapshot, localHost: String = "macair",
                     handshake: [String: JSON]? = nil, plan: QuotaSnapshot? = nil,
                     cache: ApiBodyCache = ApiBodyCache()) -> ApiResult {
        handleApi(ApiRequest(target: target), snap, localHost,
                  handshake: handshake, plan: plan, cache: cache)
    }

    func testOverviewTotalsByHostAndFreshnessPassthrough() {
        let r = get("/api/overview", makeSnap())
        XCTAssertEqual(r.status, 200)
        let b = r.body
        XCTAssertEqual(b["totalTokens"]?.num, 133)
        XCTAssertEqual(b["calls"]?.num, 3)
        XCTAssertEqual(b["byHost"]?["macair"]?["tokens"]?.num, 116)
        XCTAssertEqual(b["byHost"]?["macpro"]?["tokens"]?.num, 17)
        XCTAssertEqual(b["fetchedAt"]?.num, 1234)
        XCTAssertEqual(b["errors"]?.arr?.compactMap(\.str), ["earlier refresh failed"])
    }

    func testOverviewExposesLastSuccessAtAndEstimatedCost() {
        let b = get("/api/overview", makeSnap()).body
        XCTAssertEqual(b["lastSuccessAt"]?.num, 1200)
        // 估算成本 = costEstimated 行的成本和（gpt-5.2 那行 cost=null，不计入）→ 0
        XCTAssertEqual(b["estimatedCost"]?.num, 0)
        XCTAssertEqual(b["allTime"]?["estimatedCost"]?.num, 0)
    }

    func testOverviewRangeScopesTopLevelAndPreservesAllTime() {
        let ranged = Snapshot(rows: [
            UsageRow(host: "macair", tool: "zcode", model: "m", ts: NOW - 1 * HOUR, project: "p",
                     tin: 100, tout: 50, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 1, costEstimated: false),
            UsageRow(host: "macpro", tool: "codex", model: "m", ts: NOW - 40 * DAY, project: "q",
                     tin: 7, tout: 3, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.5, costEstimated: false),
        ], fetchedAt: 1234, lastSuccessAt: 1234)
        let b = get("/api/overview?range=7d", ranged).body
        XCTAssertEqual(b["totalTokens"]?.num, 150)
        XCTAssertEqual(b["calls"]?.num, 1)
        XCTAssertEqual(b["allTime"]?["totalTokens"]?.num, 160)
        XCTAssertEqual(b["allTime"]?["calls"]?.num, 2)
        XCTAssertEqual(b["allTime"]?["byHost"]?["macair"]?["tokens"]?.num, 150)
        XCTAssertEqual(b["allTime"]?["byHost"]?["macpro"]?["tokens"]?.num, 10)
        XCTAssertNil(b["allTime"]?["fetchedAt"])
        XCTAssertNil(b["allTime"]?["errors"])
        XCTAssertEqual(b["fetchedAt"]?.num, 1234)
        XCTAssertEqual(b["errors"]?.arr?.count, 0)
    }

    func testOverviewRangeAllKeepsTopLevelIdenticalToAllTime() {
        let b = get("/api/overview?range=all", makeSnap()).body
        XCTAssertEqual(b["totalTokens"]?.num, 133)
        XCTAssertEqual(b["allTime"]?["totalTokens"]?.num, 133)
        XCTAssertEqual(b["allTime"]?["totalCost"]?.num, 9.5)
        XCTAssertEqual(b["allTime"]?["estimatedCost"]?.num, 0)
        XCTAssertEqual(b["cacheHitRate"]?.num, b["allTime"]?["cacheHitRate"]?.num)
        XCTAssertEqual(b["activeDays"]?.num, b["allTime"]?["activeDays"]?.num)
    }

    func testOverviewAppliesDimensionFiltersToTotals() {
        let b = get("/api/overview?hosts=macpro&range=all", makeSnap()).body
        XCTAssertEqual(b["totalTokens"]?.num, 17)
        XCTAssertEqual(b["calls"]?.num, 2)
        // 分面：byHost 忽略 hosts 过滤 → 两台设备仍在
        XCTAssertEqual(Set(b["byHost"]?.obj?.keys ?? [:].keys), Set(["macair", "macpro"]))
        XCTAssertEqual(b["byHost"]?["macair"]?["tokens"]?.num, 116)
        // byTool 不忽略 hosts 过滤 → 只剩 macpro 上用过的工具
        XCTAssertEqual(Array(b["byTool"]?.obj?.keys ?? [:].keys), ["codex"])
        XCTAssertEqual(get("/api/overview?models=glm-5.2&range=all", makeSnap()).body["totalTokens"]?.num, 116)
        XCTAssertEqual(get("/api/overview?projects=p&range=all", makeSnap()).body["totalTokens"]?.num, 116)
    }

    func testOverviewComparePreviousAggregatesPreviousWindow() {
        let ranged = Snapshot(rows: [
            UsageRow(host: "macair", tool: "zcode", model: "m", ts: NOW - 1 * HOUR, project: "p",
                     tin: 100, tout: 50, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 1, costEstimated: false),
            UsageRow(host: "macpro", tool: "codex", model: "m", ts: NOW - 10 * DAY, project: "q",
                     tin: 20, tout: 10, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.5, costEstimated: false),
            UsageRow(host: "macpro", tool: "codex", model: "m", ts: NOW - 18 * DAY, project: "q",
                     tin: 7, tout: 3, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.5, costEstimated: false),
        ], fetchedAt: 1234, lastSuccessAt: 1234)
        let b = get("/api/overview?range=7d&compare=previous", ranged).body
        XCTAssertEqual(b["totalTokens"]?.num, 150)
        XCTAssertEqual(b["prev"]?["totalTokens"]?.num, 30)
        XCTAssertEqual(b["prev"]?["totalCost"]?.num, 0.5)
        XCTAssertEqual(b["prev"]?["calls"]?.num, 1)
        XCTAssertEqual(b["prev"]?["activeDays"]?.num, 1)
        // 不带 compare → prev 为 null
        let plain = get("/api/overview?range=7d", ranged).body
        XCTAssertTrue(plain["prev"]?.isNull ?? false)
        let allTime = get("/api/overview?range=all&compare=previous", makeSnap()).body
        XCTAssertTrue(allTime["prev"]?.isNull ?? false)
        // 未知 compare 值 → 400
        XCTAssertEqual(get("/api/overview?compare=bogus", makeSnap()).status, 400)
    }

    func testOverviewRangeTodayCoversSinceLocalMidnight() {
        let midnight = localMidnight(Date.nowMs())
        let ranged = Snapshot(rows: [
            UsageRow(host: "macair", tool: "zcode", model: "m", ts: midnight + 60_000, project: "p",
                     tin: 11, tout: 0, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 0.1, costEstimated: false),
            UsageRow(host: "macair", tool: "zcode", model: "m", ts: NOW - 2 * DAY, project: "p",
                     tin: 99, tout: 0, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 1, costEstimated: false),
        ], fetchedAt: 1234, lastSuccessAt: 1234)
        let b = get("/api/overview?range=today", ranged).body
        XCTAssertEqual(b["totalTokens"]?.num, 11)
        XCTAssertEqual(b["calls"]?.num, 1)
        XCTAssertEqual(b["allTime"]?["totalTokens"]?.num, 110)
    }

    func testSeriesGroupTotalMergesIntoSingleSeries() {
        let b = get("/api/series?group=total", makeSnap()).body
        XCTAssertEqual(Array(b["series"]?.obj?.keys ?? [:].keys), ["总计"])
        let sum = (b["series"]?["总计"]?.arr ?? []).reduce(0.0) { $0 + ($1.num ?? 0) }
        XCTAssertEqual(sum, 133)
    }

    func testSeriesDefaultsAndRange7d() {
        let all = get("/api/series", makeSnap()).body
        XCTAssertEqual(Set(all["series"]?.obj?.keys ?? [:].keys), Set(["glm-5.2", "gpt-5.2"]))
        let sum = all["series"]?.obj?.values.flatMap { $0.arr ?? [] }.reduce(0.0) { $0 + ($1.num ?? 0) }
        XCTAssertEqual(sum ?? -1, 133)
        XCTAssertEqual(all["unit"]?.str, "tokens")
        let week = get("/api/series?bucket=day&group=host&range=7d", makeSnap()).body
        let macair = (week["series"]?["macair"]?.arr ?? []).reduce(0.0) { $0 + ($1.num ?? 0) }
        let macpro = (week["series"]?["macpro"]?.arr ?? []).reduce(0.0) { $0 + ($1.num ?? 0) }
        XCTAssertEqual(macair, 116)
        // 40 天前的 macpro 行被 7d 窗口排除
        XCTAssertEqual(macpro, 3)
    }

    func testSeriesAppliesDimensionFilters() {
        let b = get("/api/series?group=host&hosts=macair", makeSnap()).body
        XCTAssertEqual(Array(b["series"]?.obj?.keys ?? [:].keys), ["macair"])
    }

    func testMatrixDefaultsToHostRowsModelColumnsAndHonorsFilters() {
        let r = get("/api/matrix", makeSnap())
        XCTAssertEqual(r.status, 200)
        let b = r.body
        XCTAssertEqual(b["rowKeys"]?.arr?.compactMap(\.str), ["macair", "macpro"])
        XCTAssertEqual(b["colKeys"]?.arr?.compactMap(\.str), ["glm-5.2", "gpt-5.2"])
        // macpro 上是两行 gpt-5.2（3 + 14 tokens）
        XCTAssertEqual(b["values"]?.arr?.compactMap { row in
            row.arr?.map { $0.num }
        }, [[116.0, nil], [nil, 17.0]])
        let byProject = get("/api/matrix?rows=project", makeSnap()).body
        XCTAssertEqual(byProject["rowKeys"]?.arr?.compactMap(\.str), ["p", "q"])
        // 统一筛选：hosts + range 都生效；过滤后 colKeys 只剩范围内模型
        let filtered = get("/api/matrix?rows=host&hosts=macair&range=7d", makeSnap()).body
        XCTAssertEqual(filtered["rowKeys"]?.arr?.compactMap(\.str), ["macair"])
        XCTAssertEqual(filtered["colKeys"]?.arr?.compactMap(\.str), ["glm-5.2"])
        XCTAssertEqual(filtered["values"]?.arr?.compactMap { $0.arr?.map(\.num) }, [[116.0]])
    }

    func testModelsSortedByTokensAndHonorsFilters() {
        let r = get("/api/models", makeSnap())
        XCTAssertEqual(r.status, 200)
        let b = r.body
        let models = b.arr?.compactMap { $0["model"]?.str }
        // glm-5.2: 116 tokens；gpt-5.2: 17 → glm-5.2 在前
        XCTAssertEqual(models, ["glm-5.2", "gpt-5.2"])
        XCTAssertEqual(b.arr?.first?["calls"]?.num, 1)
        XCTAssertEqual(b.arr?.first?["tokens"]?.num, 116)
        let filtered = get("/api/models?tools=codex", makeSnap()).body
        XCTAssertEqual(filtered.arr?.compactMap { $0["model"]?.str }, ["gpt-5.2"])
    }

    func testStatusReportsLocalHostAndFreshnessSplit() {
        let r = get("/api/status", makeSnap())
        XCTAssertEqual(r.status, 200)
        let b = r.body
        XCTAssertEqual(b["localHost"]?.str, "macair")
        XCTAssertEqual(b["fetchedAt"]?.num, 1234)
        XCTAssertEqual(b["lastSuccessAt"]?.num, 1200)
        XCTAssertEqual(b["refreshing"]?.bool, false)
        XCTAssertEqual(b["errors"]?.arr?.compactMap(\.str), ["earlier refresh failed"])
        XCTAssertEqual(b["recordCount"]?.num, 3)
    }

    func testStatusMergesEntrypointHandshake() {
        let b = get("/api/status", makeSnap(), handshake: [
            "instanceId": .str("id-1"),
            "configPath": .str("/x/agg.config.json"),
            "port": .num(8317),
        ]).body
        XCTAssertEqual(b["instanceId"]?.str, "id-1")
        XCTAssertEqual(b["configPath"]?.str, "/x/agg.config.json")
        XCTAssertEqual(b["port"]?.num, 8317)
    }

    func testInvalidQueryParamsReturn400WithMessage() {
        for target in [
            "/api/overview?range=bogus",
            "/api/series?bucket=week",
            "/api/series?group=galaxy",
            "/api/series?metric=horses",
            "/api/matrix?rows=nothing",
            "/api/models?range=1h",
        ] {
            let r = get(target, makeSnap())
            XCTAssertEqual(r.status, 400, target)
            let msg = r.body["error"]?.str ?? ""
            XCTAssertTrue(msg.contains("未知") || msg.contains("不合法"), target)
        }
    }

    func testPlanPassesPolledSnapshotOrEmptyAccounts() {
        let plan = QuotaSnapshot(accounts: [
            QuotaAccount(kind: .glm, label: "GLM Coding Plan", available: true,
                         unavailableReason: nil, error: nil, planName: "GLM Coding Pro",
                         windows: [], fetchedAt: 1, lastSuccessAt: 1),
        ])
        let withPlan = get("/api/plan", makeSnap(), plan: plan).body
        XCTAssertEqual(withPlan["accounts"]?.arr?.first?["planName"]?.str, "GLM Coding Pro")
        let without = get("/api/plan", makeSnap()).body
        XCTAssertNotNil(without["accounts"]?.arr)
    }

    func testUnknownApiPathReturns404() {
        let r = get("/api/nope", makeSnap())
        XCTAssertEqual(r.status, 404)
        XCTAssertEqual(r.body["error"]?.str, "not found")
    }

    func testBodyCacheReusesSameSnapshotAndInvalidatesOnNewSnapshot() {
        let snap = makeSnap()
        let cache = ApiBodyCache()
        // 同一快照两次请求（同 key）命中缓存
        _ = get("/api/overview", snap, cache: cache)
        _ = get("/api/overview", snap, cache: cache)
        // 新快照（rows 替换）后旧缓存不串味：refresh 产生全新 Snapshot 实例
        let snap2 = Snapshot(rows: [
            UsageRow(host: "macair", tool: "zcode", model: "glm-5.2", ts: NOW - 1 * HOUR, project: "p",
                     tin: 999, tout: 5, tcacheRead: 100, tcacheWrite: 0, treason: 1, cost: 0.5, costEstimated: false),
            UsageRow(host: "macpro", tool: "codex", model: "gpt-5.2", ts: NOW - 2 * DAY, project: "q",
                     tin: 1, tout: 2, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: nil, costEstimated: true),
            UsageRow(host: "macpro", tool: "codex", model: "gpt-5.2", ts: NOW - 40 * DAY, project: "q",
                     tin: 7, tout: 7, tcacheRead: 0, tcacheWrite: 0, treason: 0, cost: 9, costEstimated: false),
        ], fetchedAt: 1234, lastSuccessAt: 1200)
        let r2 = get("/api/overview", snap2, cache: cache)
        XCTAssertEqual(r2.body["totalTokens"]?.num, 133 + 999 - 10)
    }
}
