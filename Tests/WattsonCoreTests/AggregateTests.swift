// AggregateTests.swift — server/tests/aggregate.test.ts 的移植。
import XCTest
@testable import WattsonCore

final class AggregateTests: XCTestCase {
    /// 与 TS 测试一致的行构造器（缺省字段同默认）
    private func row(_ partial: (inout UsageRow) -> Void = { _ in }) -> UsageRow {
        var r = UsageRow(host: "macair", tool: "zcode", model: "m1", ts: 0, project: "p",
                         tin: 0, tout: 0, tcacheRead: 0, tcacheWrite: 0, treason: 0,
                         cost: 0, costEstimated: false)
        partial(&r)
        return r
    }

    /// 本地时区里 2026 年第一个非 24h 的日历日起点（DST 切换日）；无 DST 时区返回 nil
    private func firstDstTransitionDayStart() -> Double? {
        let cal = Calendar.current
        var comps = DateComponents()
        comps.year = 2026
        for month in 1...12 {
            for day in 1...31 {
                comps.month = month; comps.day = day
                guard let d0 = cal.date(from: comps) else { continue }
                guard let d1 = cal.date(byAdding: .day, value: 1, to: d0) else { continue }
                if d1.timeIntervalSince(d0) != DAY / 1000 { return d0.timeIntervalSince1970 * 1000 }
            }
        }
        return nil
    }

    private func makeCache(_ calls: [CachedCall], key: String = "/Users/tester/.zcode/cli/db/db.sqlite:s1") -> SessionCache {
        SessionCache(providers: [
            "zcode": ProviderSection(envFingerprint: "x", files: [
                key: CachedFile(
                    fingerprint: FileFingerprint(dev: 1, ino: 1, mtimeMs: 1, sizeBytes: 1),
                    turns: [CachedTurn(timestamp: "2026-09-10T02:00:00.000Z", sessionId: "s1", calls: calls)]),
            ]),
        ])
    }

    // MARK: rowsFromCache

    func testRowsFromCacheFlattensCacheWithHostFromPathPrefix() throws {
        let remoteDb = expandHome("~/mirror/zcode/db.sqlite")
        let remoteKey = remoteDb + ":s2"
        let cache = SessionCache(providers: [
            "zcode": ProviderSection(envFingerprint: "x", files: [
                "/Users/tester/.zcode/cli/db/db.sqlite:s1": CachedFile(
                    fingerprint: FileFingerprint(dev: 1, ino: 1, mtimeMs: 1, sizeBytes: 1),
                    turns: [CachedTurn(timestamp: "2026-09-10T02:00:00.000Z", sessionId: "s1", calls: [
                        CachedCall(provider: "zcode", model: "glm-5.2",
                                   usage: CachedUsage(inputTokens: 100, outputTokens: 10, reasoningTokens: 5),
                                   costUSD: 0.01, speed: "standard",
                                   timestamp: "2026-09-10T02:00:00.000Z"),
                    ])],
                ),
                remoteKey: CachedFile(fingerprint: FileFingerprint(dev: 1, ino: 2, mtimeMs: 1, sizeBytes: 1)),
            ]),
        ])
        let devices = [DeviceRoot(host: "macpro", zcodeDb: remoteDb)]
        let rows = rowsFromCache(cache, devices, "macair")
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.host, "macair")
        XCTAssertEqual(r.tool, "zcode")
        XCTAssertEqual(r.model, "glm-5.2")
        XCTAssertEqual(r.tin, 100)
        XCTAssertEqual(r.tout, 10)
        XCTAssertEqual(r.treason, 5)
        XCTAssertEqual(r.cost ?? -1, 0.01, accuracy: 1e-12)
        XCTAssertFalse(r.costEstimated)
    }

    func testRowsFromCacheRepricesCallsWithoutStoredCostAndFlagsEstimated() {
        // glm-5.2 在内嵌价目表内 → 重估 > 0；zcode 非 reasoning-in-output，tout+treason 计费
        let cache = makeCache([
            CachedCall(provider: "zcode", model: "glm-5.2",
                       usage: CachedUsage(inputTokens: 100, outputTokens: 10, reasoningTokens: 5),
                       speed: "standard", timestamp: "2026-09-10T02:00:00.000Z"),
        ])
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 1)
        XCTAssertGreaterThan(rows[0].cost ?? 0, 0)
        XCTAssertTrue(rows[0].costEstimated)
    }

    // MARK: series

    func testSeriesDayByHostTokensWithAlignedTimesAndNullFreeGaps() {
        let rows = [
            row { $0.ts = 1_757_464_800_000; $0.tin = 100; $0.tout = 50; $0.cost = 1 },
            row { $0.ts = 1_757_464_800_000 + 1000; $0.host = "macpro"; $0.model = "m2"; $0.tin = 10; $0.tout = 5; $0.cost = nil },
            row { $0.ts = 1_757_464_800_000 + 2 * DAY; $0.tin = 7; $0.tout = 3; $0.cost = 0.5 },
        ]
        let r = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "tokens",
                       now: 1_757_464_800_000 + 3 * DAY)
        XCTAssertGreaterThanOrEqual(r.times.count, 3)
        let a = r.series["macair"]!, b = r.series["macpro"]!
        XCTAssertEqual(a.reduce(0) { $0 + ($1 ?? 0) }, 160)
        XCTAssertEqual(b.reduce(0) { $0 + ($1 ?? 0) }, 15)
        // tokens 口径绝不产出 null
        XCTAssertFalse(a.contains(nil))
        XCTAssertFalse(b.contains(nil))
    }

    func testSeriesCostMetricCarriesNullForUnpricedModels() {
        let rows = [
            row { $0.ts = 1_757_464_800_000; $0.tin = 100; $0.tout = 50; $0.cost = 1 },
            row { $0.ts = 1_757_464_800_000 + 1000; $0.host = "macpro"; $0.model = "m2"; $0.tin = 10; $0.tout = 5; $0.cost = nil },
            row { $0.ts = 1_757_464_800_000 + 2 * DAY; $0.tin = 7; $0.tout = 3; $0.cost = 0.5 },
        ]
        let r = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "cost",
                       now: 1_757_464_800_000 + 3 * DAY)
        XCTAssertTrue((r.series["macpro"] ?? []).contains(nil))
    }

    /// DST 切换日：时间网格必须落在本地桶起点上（无 DST 时区自动跳过）
    func testSeriesGridStaysOnLocalBucketStartsAcrossDstTransition() async throws {
        guard let day0 = firstDstTransitionDayStart() else { throw XCTSkip() }
        let rows = [
            row { $0.ts = day0 - 12 * HOUR; $0.tin = 1 },
            row { $0.ts = day0 + 3 * HOUR; $0.tin = 4 },
            row { $0.ts = day0 + 36 * HOUR; $0.tin = 2 },
        ]
        let r = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "tokens",
                       now: day0 + 36 * HOUR)
        // Oracle：用日历算术枚举本地零点（Calendar 处理 DST）
        var expected: [Double] = []
        var cal = Calendar.current
        cal.timeZone = .current
        var d = Date(timeIntervalSince1970: rows[0].ts / 1000)
        d = cal.startOfDay(for: d)
        while d.timeIntervalSince1970 * 1000 <= rows[2].ts {
            expected.append(d.timeIntervalSince1970 * 1000)
            guard let next = cal.date(byAdding: .day, value: 1, to: d) else { break }
            d = cal.startOfDay(for: next)
        }
        XCTAssertEqual(r.times, expected)
        XCTAssertEqual(r.series["macair"]!.map { $0 ?? -1 }, [1, 4, 2])
    }

    // MARK: rowTokens / 统一口径

    func testRowTokensDoesNotDoubleCountReasoningForReasoningInOutputProviders() {
        // 修复前：rowTokens 无条件 tout+treason → codex/claude/copilot 的总量系统性偏高
        let codex = row { $0.tool = "codex"; $0.tin = 100; $0.tout = 50; $0.treason = 20 }
        XCTAssertEqual(rowTokens(codex), 150)
        let zcode = row { $0.tool = "zcode"; $0.tin = 100; $0.tout = 50; $0.treason = 20 }
        XCTAssertEqual(rowTokens(zcode), 170)
    }

    func testOverviewMatrixSeriesShareTheSameTokenSemantics() {
        let rows = [row { $0.host = "h1"; $0.model = "m1"; $0.tool = "codex"; $0.tin = 100; $0.tout = 50; $0.treason = 20 }]
        XCTAssertEqual(overview(rows).totalTokens, 150)
        XCTAssertEqual(matrix(rows, "host").values[0][0] ?? -1, 150)
        let s = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "tokens", now: Date.nowMs())
        let total = s.series.values.flatMap { $0 }.reduce(0) { $0 + ($1 ?? 0) }
        XCTAssertEqual(total, 150)
    }

    // MARK: 字典键安全（Swift 字典无原型继承，语义性回归保护）

    func testAggregationSurvivesReservedWordsAsHostNames() {
        let rows = [
            row { $0.host = "constructor"; $0.tin = 5 },
            row { $0.host = "hasOwnProperty"; $0.tin = 7 },
            row { $0.host = "normal"; $0.tin = 1 },
        ]
        let o = overview(rows)
        XCTAssertEqual(Set(o.byHost.keys), Set(["constructor", "hasOwnProperty", "normal"]))
        XCTAssertEqual(o.byHost["constructor"]?.tokens, 5)
        let s = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "tokens", now: 0)
        XCTAssertEqual(Set(s.series.keys), Set(["constructor", "hasOwnProperty", "normal"]))
        XCTAssertEqual((s.series["hasOwnProperty"] ?? []).reduce(0) { $0 + ($1 ?? 0) }, 7)
    }

    // MARK: filterRows

    func testFilterRowsCombinesRangeAndDimensionSets() {
        let rows = [
            row { $0.ts = 10 * DAY; $0.host = "a"; $0.tool = "zcode"; $0.model = "m1"; $0.project = "p1"; $0.tin = 1 },
            row { $0.ts = 2 * DAY; $0.host = "b"; $0.tool = "codex"; $0.model = "m2"; $0.project = "p2"; $0.tin = 2 },
        ]
        let now = 10 * DAY
        XCTAssertEqual(filterRows(rows, RowFilter(rangeMs: 5 * DAY), now), [rows[0]])
        XCTAssertEqual(filterRows(rows, RowFilter(hosts: ["b"]), now), [rows[1]])
        XCTAssertEqual(filterRows(rows, RowFilter(tools: ["codex"]), now), [rows[1]])
        XCTAssertEqual(filterRows(rows, RowFilter(models: ["m1", "m2"]), now).count, 2)
        XCTAssertEqual(filterRows(rows, RowFilter(projects: ["none"]), now).count, 0)
    }

    // MARK: series 资源边界

    func testSeriesMaxSeriesMergesTailGroupsIntoOthers() {
        let rows = (0..<15).map { i in
            row { $0.host = String(format: "h%02d", i); $0.tin = Double((i + 1) * 10) }
        }
        let r = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "tokens",
                       now: 10 * DAY, maxSeries: 5)
        XCTAssertEqual(r.series.count, 5)
        XCTAssertTrue(r.series.keys.contains("其他"))
        let sum = r.series.values.flatMap { $0 }.reduce(0) { $0 + ($1 ?? 0) }
        XCTAssertEqual(sum, 1200)
        XCTAssertNotNil(r.series["h14"])
        XCTAssertNotNil(r.series["h11"])
        XCTAssertNil(r.series["h10"])
        XCTAssertEqual((r.series["其他"] ?? []).reduce(0) { $0 + ($1 ?? 0) }, 660)
    }

    func testSeriesMaxBucketsKeepsOnlyRecentBuckets() {
        let rows = [row { $0.ts = 0; $0.host = "old"; $0.tin = 5 },
                    row { $0.ts = 3 * DAY; $0.host = "new"; $0.tin = 7 }]
        let r = series(rows, bucket: "day", group: "host", rangeMs: nil, metric: "tokens",
                       now: 3 * DAY, maxBuckets: 2)
        XCTAssertEqual(r.times.count, 2)
        XCTAssertNil(r.series["old"])
        XCTAssertEqual((r.series["new"] ?? []).reduce(0) { $0 + ($1 ?? 0) }, 7)
    }

    // MARK: overview

    func testOverviewTotalsAndCacheHitRate() {
        let rows = [
            row { $0.tin = 100; $0.tout = 50; $0.tcacheRead = 100; $0.tcacheWrite = 20; $0.treason = 10; $0.cost = 1 },
            row { $0.host = "macpro"; $0.tin = 10; $0.tout = 5; $0.cost = nil },
        ]
        let o = overview(rows)
        XCTAssertEqual(o.totalTokens, 295)
        XCTAssertEqual(o.totalCost ?? -1, 1, accuracy: 1e-12)
        XCTAssertEqual(o.calls, 2)
        XCTAssertEqual(o.cacheHitRate ?? -1, 100.0 / 210.0, accuracy: 1e-12)
        XCTAssertEqual(o.activeDays, 1)
        XCTAssertEqual(o.byHost["macair"]?.tokens, 280)
    }

    // MARK: matrix / modelTable

    func testMatrixAggregatesTokensByRowTimesModel() {
        let rows = [
            row { $0.host = "macair"; $0.model = "m1"; $0.tin = 10; $0.tout = 5 },
            row { $0.host = "macpro"; $0.model = "m1"; $0.tin = 1; $0.tout = 1 },
            row { $0.host = "macpro"; $0.model = "m2"; $0.tin = 2; $0.tout = 2 },
        ]
        let m = matrix(rows, "host")
        XCTAssertEqual(Set(m.rowKeys), Set(["macair", "macpro"]))
        XCTAssertEqual(Set(m.colKeys), Set(["m1", "m2"]))
        XCTAssertEqual(m.values, [[15, nil], [2, 4]])
    }

    func testModelTableMergesAcrossHosts() {
        let rows = [
            row { $0.host = "macair"; $0.model = "m1"; $0.tin = 10; $0.tout = 5 },
            row { $0.host = "macpro"; $0.model = "m1"; $0.tin = 1; $0.tout = 1 },
        ]
        let t = modelTable(rows)
        XCTAssertEqual(t.count, 1)
        XCTAssertEqual(t[0].calls, 2)
        XCTAssertEqual(t[0].tin, 11)
    }
}
