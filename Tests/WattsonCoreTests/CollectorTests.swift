// CollectorTests.swift — server/tests/collector.test.ts 的移植：
// Collector.refresh 并发合并 + 错误处理 + 新鲜度拆分（parseAll/loadCache 注入）。
import XCTest
@testable import WattsonCore

final class CollectorTests: XCTestCase {
    private static func makeCache() -> SessionCache {
        SessionCache(providers: [
            "zcode": ProviderSection(envFingerprint: "x", files: [
                "/Users/x/.zcode/cli/db/db.sqlite:s1": CachedFile(
                    fingerprint: FileFingerprint(dev: 1, ino: 1, mtimeMs: 1, sizeBytes: 1),
                    turns: [CachedTurn(timestamp: "2026-09-10T02:00:00.000Z", sessionId: "s1", calls: [
                        CachedCall(provider: "zcode", model: "glm-5.2",
                                   usage: CachedUsage(inputTokens: 10, outputTokens: 5, reasoningTokens: 1),
                                   costUSD: 0.01, speed: "standard",
                                   timestamp: "2026-09-10T02:00:00.000Z"),
                    ])],
                ),
            ]),
        ])
    }

    func testCoalescesConcurrentRefreshCallsIntoSingleParse() async {
        let box = ParseBox()
        let collector = Collector(
            devices: [], localHost: "testhost",
            parseAll: { box.parseCalls += 1; await box.gate.wait() },
            loadCache: { Self.makeCache() })
        // 三个背靠背调用共享同一轮 in-flight 刷新
        let p1 = Task { await collector.refresh() }
        await waitUntil { collector.snapshot.refreshing && box.parseCalls == 1 }
        let p2 = Task { await collector.refresh() }
        let p3 = Task { await collector.refresh() }
        XCTAssertEqual(box.parseCalls, 1)
        XCTAssertTrue(collector.snapshot.refreshing)
        await box.gate.resolve()
        let s1 = await p1.value
        let s2 = await p2.value
        let s3 = await p3.value
        XCTAssertEqual(box.parseCalls, 1)
        XCTAssertFalse(collector.snapshot.refreshing)
        XCTAssertEqual(s1.errors, [])
        XCTAssertEqual(s1.rows.count, 1)
        // 所有调用者拿到同一份落定快照
        XCTAssertEqual(s1, s2)
        XCTAssertEqual(s2, s3)
        XCTAssertEqual(s1, collector.snapshot)
        // 落定后锁已清空：新刷新跑新一轮 parse
        box.gate = Gate()
        let p4 = Task { await collector.refresh() }
        await waitUntil { box.parseCalls == 2 }
        await box.gate.resolve()
        _ = await p4.value
        XCTAssertEqual(box.parseCalls, 2)
    }

    func testCallsChainedOntoInflightRefreshAlsoSeeOneParse() async {
        let box = ParseBox()
        let collector = Collector(
            devices: [], localHost: "h",
            parseAll: { box.parseCalls += 1; await box.gate.wait() },
            loadCache: { Self.makeCache() })
        let first = Task { await collector.refresh() }
        await waitUntil { box.parseCalls == 1 }
        let chained = (0..<4).map { _ in Task { await collector.refresh() } }
        XCTAssertEqual(box.parseCalls, 1)
        await box.gate.resolve()
        let results = await withTaskGroup(of: Snapshot.self) { group in
            for t in chained { group.addTask { await t.value } }
            var out: [Snapshot] = []
            for await s in group { out.append(s) }
            return out
        }
        await first.value
        XCTAssertEqual(box.parseCalls, 1)
        XCTAssertTrue(results.allSatisfy { !$0.refreshing && $0.rows.count == 1 })
    }

    func testParseFailureRecordsErrorAndKeepsPreviousRows() async {
        let box = ParseBox()
        let collector = Collector(
            devices: [], localHost: "h",
            parseAll: { if box.failParse { throw TestError("cold parse exploded") } },
            loadCache: { box.loadCacheCalls += 1; return Self.makeCache() })
        let first = await collector.refresh()
        XCTAssertEqual(first.errors, [])
        XCTAssertEqual(first.rows.count, 1)
        XCTAssertNotNil(first.lastSuccessAt)

        // 第二轮：parse 爆炸；loadCache 必须被跳过，旧行保留
        box.failParse = true
        let s = await collector.refresh()
        XCTAssertEqual(s.errors, ["parseAllSessions: cold parse exploded"])
        XCTAssertEqual(s.rows, first.rows)
        XCTAssertFalse(s.refreshing)
        XCTAssertGreaterThanOrEqual(s.fetchedAt, first.fetchedAt)
        // 新鲜度拆分：失败轮 fetchedAt（尝试时间）推进，lastSuccessAt 保留旧值
        XCTAssertEqual(s.lastSuccessAt, first.lastSuccessAt)
        XCTAssertEqual(box.loadCacheCalls, 1)
    }

    func testLoadCacheFailureAlsoLandsInErrors() async {
        let collector = Collector(
            devices: [], localHost: "h",
            parseAll: {},
            loadCache: { throw TestError("cache file corrupt") })
        let s = await collector.refresh()
        XCTAssertEqual(s.errors, ["loadCache: cache file corrupt"])
        XCTAssertEqual(s.rows, [])
        XCTAssertFalse(s.refreshing)
    }

    func testHappyPathRowsLandInSnapshotWithLocalHostDefault() async {
        let collector = Collector(
            devices: [], localHost: "macair",
            parseAll: {},
            loadCache: { Self.makeCache() })
        let s = await collector.refresh()
        XCTAssertEqual(s.errors, [])
        let r = s.rows.first
        XCTAssertEqual(r?.host, "macair")
        XCTAssertEqual(r?.tool, "zcode")
        XCTAssertEqual(r?.model, "glm-5.2")
        XCTAssertEqual(r?.tin, 10)
        XCTAssertEqual(r?.tout, 5)
        XCTAssertEqual(r?.treason, 1)
        XCTAssertGreaterThan(s.fetchedAt, 0)
    }
}
