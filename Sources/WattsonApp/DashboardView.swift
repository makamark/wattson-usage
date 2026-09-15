// DashboardView.swift — 原生看板窗口：KPI + 订阅额度卡片 + 用量趋势 + 模型明细。
// 数据直接取进程内的聚合/轮询结果（等价于 HTTP /api/* 的进程内调用）。
import WattsonCore
import SwiftUI
import Charts

struct DashboardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                usageSection
                quotaSection
                if let series = seriesData {
                    trendSection(series)
                }
                modelSection
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("Wattson 看板")
        .task { await state.refreshNow() }
    }

    // MARK: 头部状态

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本机 \(state.collector.localHost) · \(Int(state.snapshot.rows.count)) 条用量记录 · v\(WATTSON_VERSION)-native")
                    .font(.headline)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let note = state.proxyNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Button(state.refreshing ? "采集中…" : "立即刷新") {
                Task { await state.refreshNow() }
            }
            .disabled(state.refreshing)
        }
    }

    private var statusLine: String {
        var parts: [String] = []
        if state.snapshot.lastSuccessAt != nil {
            parts.append("数据时间 \(formatTime(state.snapshot.fetchedAt))")
        }
        for e in state.snapshot.errors { parts.append("⚠︎ \(e)") }
        if parts.isEmpty { parts = ["首次采集中…"] }
        return parts.joined(separator: " · ")
    }

    // MARK: KPI

    private var overviewData: OverviewResult? {
        let now = Date.nowMs()
        let filter = RowFilter(rangeMs: 30 * DAY_MS)
        return overview(filterRows(state.snapshot.rows, filter, now))
    }

    private var usageSection: some View {
        let o = overviewData
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
            kpiCard("近 30 天 Token", o.map { formatTokens($0.totalTokens) } ?? "—")
            kpiCard("估算成本", o?.totalCost.map { String(format: "$%.2f", $0) } ?? "—")
            kpiCard("调用次数", o.map { "\(Int($0.calls))" } ?? "—")
            kpiCard("缓存命中率", o?.cacheHitRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—")
            kpiCard("活跃天数", o.map { "\($0.activeDays)" } ?? "—")
        }
    }

    private func kpiCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3).fontWeight(.semibold).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 订阅额度卡片

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("订阅额度").font(.headline)
            let available = state.quota.accounts.filter(\.available)
            let unavailable = state.quota.accounts.filter { !$0.available && $0.unavailableReason != "no_credentials" && $0.unavailableReason != "loading" }
            if available.isEmpty && unavailable.isEmpty {
                Text("未发现可用的订阅账号（凭据缺失的账号自动隐藏）")
                    .font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 340), spacing: 12), count: 3), spacing: 12) {
                ForEach(available, id: \.self) { QuotaCard(account: $0) }
                ForEach(unavailable, id: \.self) { QuotaCard(account: $0) }
            }
        }
    }

    // MARK: 趋势图

    private var seriesData: SeriesResult? {
        guard !state.snapshot.rows.isEmpty else { return nil }
        let now = Date.nowMs()
        let filter = RowFilter(rangeMs: 30 * DAY_MS)
        return series(filterRows(state.snapshot.rows, filter, now),
                      bucket: "day", group: "total", rangeMs: nil, metric: "tokens", now: now)
    }

    private func trendSection(_ s: SeriesResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("用量趋势（每日 Token，近 30 天）").font(.headline)
            let points: [(day: Date, tokens: Double)] = zip(s.times, s.series["总计"] ?? []).compactMap { t, v in
                v.map { (Date(timeIntervalSince1970: t / 1000), $0) }
            }
            Chart(points, id: \.day) { p in
                BarMark(
                    x: .value("日期", p.day, unit: .day),
                    y: .value("Token", p.tokens)
                )
                .foregroundStyle(Color.accentColor.opacity(0.8))
                .cornerRadius(2)
            }
            .frame(height: 180)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    // MARK: 模型明细

    private var modelSection: some View {
        let entries = modelTable(state.snapshot.rows)
        return VStack(alignment: .leading, spacing: 8) {
            Text("模型明细（全历史，按 Token 降序）").font(.headline)
            if entries.isEmpty {
                Text("暂无数据：装了任一受支持工具并在其产生用量后自动出现").font(.caption).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("模型").font(.caption).bold()
                        Text("调用").font(.caption).bold()
                        Text("输入").font(.caption).bold()
                        Text("输出").font(.caption).bold()
                        Text("缓存读").font(.caption).bold()
                        Text("Token").font(.caption).bold()
                        Text("成本").font(.caption).bold()
                    }
                    Divider()
                    ForEach(entries.prefix(20), id: \.model) { e in
                        GridRow {
                            Text(e.model).font(.caption).lineLimit(1)
                            Text("\(Int(e.calls))").font(.caption).monospacedDigit()
                            Text(formatTokens(e.tin)).font(.caption).monospacedDigit()
                            Text(formatTokens(e.tout)).font(.caption).monospacedDigit()
                            Text(formatTokens(e.tcacheRead)).font(.caption).monospacedDigit()
                            Text(formatTokens(e.tokens)).font(.caption).monospacedDigit().bold()
                            Text(e.cost.map { String(format: "$%.2f", $0) } ?? "—").font(.caption).monospacedDigit()
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }
}

// MARK: - 单张额度卡片

struct QuotaCard: View {
    let account: QuotaAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(account.label).font(.subheadline).fontWeight(.semibold)
                Spacer()
                if let plan = account.planName {
                    Text(plan).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                }
            }
            if account.available {
                ForEach(account.windows, id: \.key) { window in
                    HStack {
                        Text(window.label).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(resetText(window.nextResetAt)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    ProgressView(value: (window.percentage ?? 0) / 100)
                        .progressViewStyle(.linear)
                    Text(windowPercent(window))
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                Text(unavailableText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var unavailableText: String {
        switch account.unavailableReason {
        case "http_401": return "凭据无效或已过期"
        case "http_error": return "接口不可达\(account.error.map { "：\($0)" } ?? "")"
        case "no_plan": return "账号未订阅套餐"
        case "error": return account.error ?? "未知错误"
        default: return "暂不可用"
        }
    }

    private func windowPercent(_ w: QuotaWindow) -> String {
        guard let p = w.percentage else { return "" }
        if let total = w.total, let used = w.used {
            return String(format: "%.0f%%（%@ / %@）", p, formatTokens(used), formatTokens(total))
        }
        return String(format: "%.0f%% 已用", p)
    }

    private func resetText(_ ms: Double?) -> String {
        guard let ms else { return "" }
        let delta = ms - Date.nowMs()
        guard delta > 0 else { return "" }
        let hours = delta / 3600_000
        if hours >= 24 { return "\(Int(hours / 24)) 天后重置" }
        return String(format: "%.1f 小时后重置", hours)
    }
}

func formatTime(_ ms: Double) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = "MM-dd HH:mm"
    return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

let DAY_MS: Double = 24 * 3600 * 1000
