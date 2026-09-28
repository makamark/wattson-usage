// Core/Heatmap.swift — GitHub 风格活动热力图聚合（纯函数，看板与测试共用）。
// 口径：列 = 自然周（周一起），行 = 周一…周日；每日值 = rowTokens（与 KPI
// 「Token 总量」同口径）。日桶用注入 Calendar 的 startOfDay 计算（DST 安全），
// 不复用 series 的 bucketStart：这里要求测试可用固定时区做精确断言。
import Foundation

public struct HeatmapDay: Sendable, Equatable {
    public var dayStart: Double   // 本地日桶起点（epoch 毫秒）
    public var tokens: Double
    public var calls: Double

    public init(dayStart: Double, tokens: Double, calls: Double) {
        self.dayStart = dayStart
        self.tokens = tokens
        self.calls = calls
    }
}

public struct HeatmapResult: Sendable, Equatable {
    /// 第一列顶部（该周周一起点之前）的空单元格数
    public var leadingBlanks: Int
    /// 窗口内每个本地日一项（无数据日 tokens=0），升序
    public var days: [HeatmapDay]
    public var maxTokens: Double
    public var totalTokens: Double
    public var activeDays: Int
    /// 以窗口最后一天收尾、连续有数据的天数（0 = 最后一天不活跃）
    public var streakDays: Int

    public init(leadingBlanks: Int, days: [HeatmapDay], maxTokens: Double,
                totalTokens: Double, activeDays: Int, streakDays: Int) {
        self.leadingBlanks = leadingBlanks
        self.days = days
        self.maxTokens = maxTokens
        self.totalTokens = totalTokens
        self.activeDays = activeDays
        self.streakDays = streakDays
    }

    /// 网格布局：columns[i][j]，i = 第几周列，j = 周一(0)…周日(6)；nil = 空位。
    /// 依赖 days 为连续本地日的恒定性（日历日不跳星期，DST 也不影响星期推进）。
    public var columns: [[HeatmapDay?]] {
        var cols: [[HeatmapDay?]] = []
        var current: [HeatmapDay?] = Array(repeating: nil, count: leadingBlanks)
        for day in days {
            current.append(day)
            if current.count == 7 {
                cols.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            cols.append(current + Array(repeating: nil, count: 7 - current.count))
        }
        return cols
    }
}

func heatmapDayStart(_ ms: Double, _ cal: Calendar) -> Double {
    cal.startOfDay(for: Date(timeIntervalSince1970: ms / 1000)).timeIntervalSince1970 * 1000
}

public func heatmapDays(_ rows: [UsageRow], weeks: Int, now: Double,
                        calendar: Calendar = .current) -> HeatmapResult {
    let window = max(1, weeks)
    let dayMs: Double = 24 * 3600 * 1000
    let endDay = heatmapDayStart(now, calendar)
    let windowStart = endDay - Double(window * 7 - 1) * dayMs
    // weekday: 1=周日…7=周六；换算成周一=0 的列索引
    let leadingBlanks = (calendar.component(
        .weekday, from: Date(timeIntervalSince1970: windowStart / 1000)) + 5) % 7

    var tokens: [Double: Double] = [:]
    var calls: [Double: Double] = [:]
    for r in rows {
        let day = heatmapDayStart(r.ts, calendar)
        guard day >= windowStart, day <= endDay else { continue }
        tokens[day, default: 0] += rowTokens(r)
        calls[day, default: 0] += 1
    }

    // 逐本地日推进：raw 步进直到 startOfDay 取得进展（跨 DST 的 23h/25h 日安全）
    var days: [HeatmapDay] = []
    var day = windowStart
    while day <= endDay {
        days.append(HeatmapDay(dayStart: day, tokens: tokens[day] ?? 0, calls: calls[day] ?? 0))
        var raw = day + dayMs
        while heatmapDayStart(raw, calendar) <= day { raw += dayMs }
        day = heatmapDayStart(raw, calendar)
    }

    let maxTokens = days.map(\.tokens).max() ?? 0
    var streak = 0
    for d in days.reversed() {
        guard d.tokens > 0 else { break }
        streak += 1
    }
    return HeatmapResult(
        leadingBlanks: leadingBlanks,
        days: days,
        maxTokens: maxTokens,
        totalTokens: days.reduce(0) { $0 + $1.tokens },
        activeDays: days.filter { $0.tokens > 0 }.count,
        streakDays: streak)
}
