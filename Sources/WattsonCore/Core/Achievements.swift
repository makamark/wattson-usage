// Core/Achievements.swift — 成就徽章（15 枚，纯本地聚合，无网络无状态）。
// 口径：token 类 = rowTokens（与 KPI「Token 总量」同口径）；夜猫子/早起鸟按
// 本地小时分桶；streak 用日历日回退（跨 DST 安全），以今天或昨天收尾取较大者
// （今天的用量可能还没产生，不能让进行中的连击被误判为断）。
import Foundation

public struct Achievement: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var detail: String
    public var achieved: Bool
    /// 未达成时的进度 0-1；已达成（或无进度概念）为 nil
    public var progress: Double?

    public init(id: String, name: String, detail: String, achieved: Bool, progress: Double? = nil) {
        self.id = id
        self.name = name
        self.detail = detail
        self.achieved = achieved
        self.progress = achieved ? nil : progress
    }
}

func streakEndingAt(_ start: Double, _ active: Set<Double>, _ cal: Calendar) -> Int {
    var day = start
    var count = 0
    while active.contains(day) {
        count += 1
        guard let prev = cal.date(byAdding: .day, value: -1,
                                  to: Date(timeIntervalSince1970: day / 1000)) else { break }
        day = cal.startOfDay(for: prev).timeIntervalSince1970 * 1000
    }
    return count
}

public func achievements(_ rows: [UsageRow], now: Double, calendar: Calendar = .current) -> [Achievement] {
    var totalTokens: Double = 0, calls: Double = 0, cost: Double = 0, costSeen = false
    var cacheRead: Double = 0, freshInput: Double = 0
    var models = Set<String>(), tools = Set<String>()
    var hosts = Set<String>(), projects = Set<String>()
    var nightCalls: Double = 0, earlyCalls: Double = 0
    var dayTokens: [Double: Double] = [:]
    for r in rows {
        totalTokens += rowTokens(r)
        calls += 1
        cacheRead += r.tcacheRead
        freshInput += r.tin
        if let c = r.cost { cost += c; costSeen = true }
        models.insert(r.model)
        tools.insert(r.tool)
        hosts.insert(r.host)
        projects.insert(r.project)
        let d = Date(timeIntervalSince1970: r.ts / 1000)
        let hour = calendar.component(.hour, from: d)
        if hour < 5 { nightCalls += 1 }
        if hour >= 5, hour < 8 { earlyCalls += 1 }
        dayTokens[heatmapDayStart(r.ts, calendar), default: 0] += rowTokens(r)
    }
    let active = Set(dayTokens.keys)
    let today = heatmapDayStart(now, calendar)
    let yesterday = calYesterday(today, calendar)
    let bestStreak = max(streakEndingAt(today, active, calendar),
                         streakEndingAt(yesterday, active, calendar))
    let cacheRate = (freshInput + cacheRead) > 0 ? cacheRead / (freshInput + cacheRead) : 0
    let maxDay = dayTokens.values.max() ?? 0

    func progress(_ value: Double, _ target: Double) -> Double? {
        guard target > 0 else { return nil }
        return min(1, value / target)
    }
    return [
        Achievement(id: "first-call", name: "初次点火", detail: "产生第 1 次 AI 调用",
                    achieved: calls >= 1),
        Achievement(id: "tokens-1m", name: "百万 token", detail: "累计 token 达到 100 万",
                    achieved: totalTokens >= 1e6, progress: progress(totalTokens, 1e6)),
        Achievement(id: "tokens-1b", name: "十亿 token", detail: "累计 token 达到 10 亿",
                    achieved: totalTokens >= 1e9, progress: progress(totalTokens, 1e9)),
        Achievement(id: "day-peak", name: "单日百万", detail: "单日 token 峰值达到 100 万",
                    achieved: maxDay >= 1e6, progress: progress(maxDay, 1e6)),
        Achievement(id: "streak-7", name: "七日连击", detail: "连续 7 天都有用量",
                    achieved: bestStreak >= 7, progress: progress(Double(bestStreak), 7)),
        Achievement(id: "streak-30", name: "月度连击", detail: "连续 30 天都有用量",
                    achieved: bestStreak >= 30, progress: progress(Double(bestStreak), 30)),
        Achievement(id: "night-owl", name: "夜猫子", detail: "凌晨 0–5 点产生 10 次调用",
                    achieved: nightCalls >= 10, progress: progress(nightCalls, 10)),
        Achievement(id: "early-bird", name: "早起鸟", detail: "清晨 5–8 点产生 10 次调用",
                    achieved: earlyCalls >= 10, progress: progress(earlyCalls, 10)),
        Achievement(id: "polyglot", name: "百花齐放", detail: "使用过 10 种不同模型",
                    achieved: models.count >= 10, progress: progress(Double(models.count), 10)),
        Achievement(id: "tools-3", name: "三线作战", detail: "同时使用 3 种编码工具",
                    achieved: tools.count >= 3, progress: progress(Double(tools.count), 3)),
        Achievement(id: "multi-host", name: "双机联动", detail: "聚合到 2 台以上设备的数据",
                    achieved: hosts.count >= 2, progress: progress(Double(hosts.count), 2)),
        Achievement(id: "cache-master", name: "缓存大师", detail: "缓存命中率不低于 80%",
                    achieved: cacheRate >= 0.8, progress: progress(cacheRate, 0.8)),
        Achievement(id: "cost-100", name: "百元俱乐部", detail: "估算成本累计达到 $100",
                    achieved: costSeen && cost >= 100, progress: progress(cost, 100)),
        Achievement(id: "projects-5", name: "五面开工", detail: "覆盖 5 个以上项目",
                    achieved: projects.count >= 5, progress: progress(Double(projects.count), 5)),
        Achievement(id: "marathon", name: "万次调用", detail: "累计调用达到 10000 次",
                    achieved: calls >= 10000, progress: progress(calls, 10000)),
    ]
}

func calYesterday(_ dayStartMs: Double, _ cal: Calendar) -> Double {
    cal.date(byAdding: .day, value: -1, to: Date(timeIntervalSince1970: dayStartMs / 1000))
        .map { cal.startOfDay(for: $0).timeIntervalSince1970 * 1000 } ?? dayStartMs
}
