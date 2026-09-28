// HeatmapTests — 活动热力图聚合：窗口/对齐/聚合/streak/网格布局。
// 固定 UTC 时区断言（无 DST，日桶 = 86400s 整数倍）；2026-09-28 是周一。
import XCTest
@testable import WattsonCore

final class HeatmapTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Double {
        var comps = DateComponents()
        comps.year = y
        comps.month = m
        comps.day = d
        comps.hour = h
        return cal.date(from: comps)!.timeIntervalSince1970 * 1000
    }

    private func row(_ ts: Double, tin: Double = 100) -> UsageRow {
        UsageRow(host: "local", tool: "zcode", model: "glm-5", ts: ts, project: "p",
                 tin: tin, tout: 0, tcacheRead: 0, tcacheWrite: 0, treason: 0,
                 cost: nil, costEstimated: false)
    }

    func testEmptyRowsProducesFullWindow() {
        let r = heatmapDays([], weeks: 4, now: day(2026, 9, 28), calendar: cal)
        XCTAssertEqual(r.days.count, 28)
        XCTAssertEqual(r.totalTokens, 0)
        XCTAssertEqual(r.activeDays, 0)
        XCTAssertEqual(r.streakDays, 0)
        XCTAssertEqual(r.maxTokens, 0)
        // 窗口起点 = 周一 - 27 天 = 周二 → 第一列 1 个空位
        XCTAssertEqual(r.leadingBlanks, 1)
    }

    func testAggregationStreakAndColumns() {
        let rows = [
            row(day(2026, 9, 26), tin: 100),  // 周六
            row(day(2026, 9, 27), tin: 200),  // 周日
            row(day(2026, 9, 28, 23), tin: 300),  // 周一（今天，深夜）
        ]
        let r = heatmapDays(rows, weeks: 2, now: day(2026, 9, 28, 23), calendar: cal)
        XCTAssertEqual(r.days.count, 14)
        XCTAssertEqual(r.totalTokens, 600)
        XCTAssertEqual(r.maxTokens, 300)
        XCTAssertEqual(r.activeDays, 3)
        XCTAssertEqual(r.streakDays, 3)
        XCTAssertEqual(r.leadingBlanks, 1)  // 窗口起点 9/15 周二
        // 第一列：1 空位 + 从 9/15（周二）起 6 天
        XCTAssertNil(r.columns[0][0])
        XCTAssertEqual(r.columns[0][1]?.dayStart, day(2026, 9, 15, 0))
        XCTAssertEqual(r.columns.count, 3)
        // 恒定不变式：非空格子的星期与所在行一致（j=0 是周一）
        for (ci, col) in r.columns.enumerated() {
            for (ri, cell) in col.enumerated() {
                guard let cell else { continue }
                let mon0 = (cal.component(.weekday, from: Date(timeIntervalSince1970: cell.dayStart / 1000)) + 5) % 7
                XCTAssertEqual(mon0, ri, "column \(ci) row \(ri)")
            }
        }
    }

    func testRowsOutsideWindowIgnored() {
        let rows = [row(day(2026, 8, 20), tin: 500), row(day(2026, 9, 28), tin: 100)]
        let r = heatmapDays(rows, weeks: 2, now: day(2026, 9, 28), calendar: cal)
        XCTAssertEqual(r.totalTokens, 100)
        XCTAssertEqual(r.activeDays, 1)
    }

    func testStreakBreaksOnInactiveDay() {
        let rows = [row(day(2026, 9, 26)), row(day(2026, 9, 28))]
        let r = heatmapDays(rows, weeks: 2, now: day(2026, 9, 28), calendar: cal)
        XCTAssertEqual(r.streakDays, 1)  // 9/27 空档，只剩今天
    }

    func testDaysStrictlyIncreasing() {
        let r = heatmapDays([row(day(2026, 9, 1))], weeks: 8, now: day(2026, 9, 28), calendar: cal)
        XCTAssertEqual(r.days.count, 56)
        for i in 1..<r.days.count {
            XCTAssertEqual(r.days[i].dayStart - r.days[i - 1].dayStart, 24 * 3600 * 1000)
        }
    }
}
