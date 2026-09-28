// AchievementBudgetTests — 成就徽章 / 月度预算 / 时刻分布 的聚合测试。
// 固定 UTC 时区（无 DST）：2026-09-28 是周一、2026-09-30 是周三。
import XCTest
@testable import WattsonCore

private let testCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func testDay(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Double {
    var comps = DateComponents()
    comps.year = y
    comps.month = m
    comps.day = d
    comps.hour = h
    return testCal.date(from: comps)!.timeIntervalSince1970 * 1000
}

private func testRow(_ ts: Double, tin: Double = 100, model: String = "glm-5",
                     cacheRead: Double = 0, cost: Double? = nil) -> UsageRow {
    UsageRow(host: "local", tool: "zcode", model: model, ts: ts, project: "p",
             tin: tin, tout: 0, tcacheRead: cacheRead, tcacheWrite: 0, treason: 0,
             cost: cost, costEstimated: cost != nil)
}

private func badge(_ list: [Achievement], _ id: String) -> Achievement {
    list.first { $0.id == id }!
}

final class AchievementTests: XCTestCase {
    func testEmptyRowsNoAchievements() {
        let list = achievements([], now: testDay(2026, 9, 28), calendar: testCal)
        XCTAssertEqual(list.count, 15)
        XCTAssertTrue(list.allSatisfy { !$0.achieved })
    }

    func testTokenMilestonesAndProgress() {
        let list = achievements([testRow(testDay(2026, 9, 28), tin: 1_500_000)],
                                now: testDay(2026, 9, 28, 23), calendar: testCal)
        let million = badge(list, "tokens-1m")
        XCTAssertTrue(million.achieved)
        XCTAssertNil(million.progress)
        XCTAssertFalse(badge(list, "tokens-1b").achieved)
        XCTAssertTrue(badge(list, "day-peak").achieved)
        XCTAssertTrue(badge(list, "first-call").achieved)
    }

    func testStreakSevenDays() {
        // 9/22–9/28 连续 7 天
        let rows = (0..<7).map { testRow(testDay(2026, 9, 28) - Double(6 - $0) * 24 * 3600 * 1000) }
        let list = achievements(rows, now: testDay(2026, 9, 28, 23), calendar: testCal)
        XCTAssertTrue(badge(list, "streak-7").achieved)
        XCTAssertFalse(badge(list, "streak-30").achieved)
    }

    func testOngoingStreakCountsFromYesterday() {
        // 9/21–9/27 连续，今天(9/28)还没用量：连击进行中，7 天徽章应已点亮
        let rows = (0..<7).map { testRow(testDay(2026, 9, 27) - Double(6 - $0) * 24 * 3600 * 1000) }
        let list = achievements(rows, now: testDay(2026, 9, 28, 8), calendar: testCal)
        XCTAssertTrue(badge(list, "streak-7").achieved)
    }

    func testNightOwlAndPolyglot() {
        let rows = (0..<10).map {
            testRow(testDay(2026, 9, 28, 2) + Double($0) * 60_000, model: "m\($0)")
        }
        let list = achievements(rows, now: testDay(2026, 9, 28, 23), calendar: testCal)
        XCTAssertTrue(badge(list, "night-owl").achieved)
        XCTAssertTrue(badge(list, "polyglot").achieved)
        XCTAssertFalse(badge(list, "early-bird").achieved)
    }

    func testCacheMasterAndCost() {
        let list = achievements([testRow(testDay(2026, 9, 28), tin: 20, cacheRead: 80)],
                                now: testDay(2026, 9, 28, 23), calendar: testCal)
        XCTAssertTrue(badge(list, "cache-master").achieved)
        XCTAssertFalse(badge(list, "cost-100").achieved)
        let paid = achievements([testRow(testDay(2026, 9, 28), cost: 150)],
                                now: testDay(2026, 9, 28, 23), calendar: testCal)
        XCTAssertTrue(badge(paid, "cost-100").achieved)
    }
}

final class BudgetTests: XCTestCase {
    private func tmpDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wattson-budget-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ path: String, _ content: String) {
        try! FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testDisabledByDefault() {
        XCTAssertFalse(loadBudget(home: tmpDir()).enabled)
    }

    func testEnvBudgetFileHonored() {
        let home = tmpDir()
        let file = home + "/b.json"
        write(file, #"{"monthlyCost": 50}"#)
        let b = loadBudget(env: ["WATTSON_BUDGET_FILE": file], home: home)
        XCTAssertEqual(b.monthlyCost, 50)
        XCTAssertNil(b.monthlyTokens)
        XCTAssertTrue(b.enabled)
    }

    func testWarnAndOver() {
        let budget = Budget(monthlyTokens: 1000)
        XCTAssertEqual(budgetStatus([testRow(testDay(2026, 9, 15), tin: 900)],
                                    budget: budget, now: testDay(2026, 9, 20), calendar: testCal).level, .warn)
        XCTAssertEqual(budgetStatus([testRow(testDay(2026, 9, 15), tin: 1200)],
                                    budget: budget, now: testDay(2026, 9, 20), calendar: testCal).level, .over)
        XCTAssertEqual(budgetStatus([testRow(testDay(2026, 9, 15), tin: 500)],
                                    budget: budget, now: testDay(2026, 9, 20), calendar: testCal).level, .ok)
    }

    func testPreviousMonthExcluded() {
        let budget = Budget(monthlyTokens: 1000)
        let status = budgetStatus([testRow(testDay(2026, 8, 20), tin: 5000)],
                                  budget: budget, now: testDay(2026, 9, 20), calendar: testCal)
        XCTAssertEqual(status.usedTokens, 0)
        XCTAssertEqual(status.level, .ok)
    }

    func testCostBudget() {
        let budget = Budget(monthlyCost: 10)
        let status = budgetStatus([testRow(testDay(2026, 9, 15), tin: 10, cost: 12)],
                                  budget: budget, now: testDay(2026, 9, 20), calendar: testCal)
        XCTAssertEqual(status.usedCost, 12)
        XCTAssertEqual(status.level, .over)
    }
}
