// Core/Budget.swift — 月度预算告警（TS 时代 budget.ts 的原生收编）。
// 配置 ~/.config/wattson/budget.json（或 WATTSON_BUDGET_FILE 指定）：
//   { "monthlyTokens": 500000000, "monthlyCost": 100 }
// 任一字段缺省 = 该维度不限；文件缺省 = 不启用（UI 不出预算条）。
// 阈值：任一维度 ≥80% 提醒（warn），≥100% 超限（over）。
import Foundation

public struct Budget: Sendable, Equatable {
    public var monthlyTokens: Double?
    public var monthlyCost: Double?
    /// 提醒阈值（占比），默认 0.8
    public var warnRatio: Double

    public init(monthlyTokens: Double? = nil, monthlyCost: Double? = nil, warnRatio: Double = 0.8) {
        self.monthlyTokens = monthlyTokens
        self.monthlyCost = monthlyCost
        self.warnRatio = warnRatio
    }

    public var enabled: Bool { monthlyTokens != nil || monthlyCost != nil }
}

public enum BudgetLevel: String, Sendable, Equatable {
    case ok, warn, over
}

public struct BudgetStatus: Sendable, Equatable {
    public var usedTokens: Double
    public var usedCost: Double?
    public var tokenRatio: Double?
    public var costRatio: Double?
    public var level: BudgetLevel
}

func budgetFilePath(home: String? = nil) -> String {
    ((home ?? homePath()) as NSString).appendingPathComponent(".config/wattson/budget.json")
}

public func loadBudget(env: [String: String] = [:], home: String? = nil) -> Budget {
    let path = env["WATTSON_BUDGET_FILE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? budgetFilePath(home: home)
    guard let parsed = parseJSONFile(path), let obj = parsed.obj else { return Budget() }
    return Budget(monthlyTokens: quotaNum(obj["monthlyTokens"]),
                  monthlyCost: quotaNum(obj["monthlyCost"]))
}

/// 本月（now 所在自然月）已用量 vs 预算。token 口径 = rowTokens，成本口径 = UsageRow.cost。
public func budgetStatus(_ rows: [UsageRow], budget: Budget, now: Double,
                         calendar: Calendar = .current) -> BudgetStatus {
    let monthStart = (calendar.dateInterval(of: .month, for: Date(timeIntervalSince1970: now / 1000))?
        .start.timeIntervalSince1970 ?? 0) * 1000
    var tokens: Double = 0
    var cost: Double = 0
    var costSeen = false
    for r in rows where r.ts >= monthStart {
        tokens += rowTokens(r)
        if let c = r.cost { cost += c; costSeen = true }
    }
    // 上限 ≤0 视为未配置该维度（除零/负上限不产生告警）
    let tokenRatio = budget.monthlyTokens.flatMap { $0 > 0 ? tokens / $0 : nil }
    let costRatio = budget.monthlyCost.flatMap { limit in
        (costSeen && limit > 0) ? cost / limit : nil
    }
    let maxRatio = [tokenRatio, costRatio].compactMap { $0 }.max() ?? 0
    let level: BudgetLevel = maxRatio >= 1 ? .over : (maxRatio >= budget.warnRatio ? .warn : .ok)
    return BudgetStatus(usedTokens: tokens, usedCost: costSeen ? cost : nil,
                        tokenRatio: tokenRatio, costRatio: costRatio, level: level)
}
