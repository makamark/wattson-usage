// Core/Punchcard.swift — 时刻分布（周 × 小时热力），原版 punchcard 可视化的原生收编。
import Foundation

/// [7][24]：行 = 周一(0)…周日(6)，列 = 本地小时 0–23；值 = rowTokens。
public func hourProfile(_ rows: [UsageRow], calendar: Calendar = .current) -> [[Double]] {
    var grid = Array(repeating: Array(repeating: 0.0, count: 24), count: 7)
    for r in rows {
        let d = Date(timeIntervalSince1970: r.ts / 1000)
        let mon0 = (calendar.component(.weekday, from: d) + 5) % 7
        let hour = calendar.component(.hour, from: d)
        grid[mon0][hour] += rowTokens(r)
    }
    return grid
}
