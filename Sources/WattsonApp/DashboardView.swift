// DashboardView.swift — 完整看板（web 看板的 1:1 移植，单页布局）。
// 布局：顶栏（品牌 + 范围/指标切换 + 数据时间 + 刷新 + 设置齿轮）+ 全部区块
// 单页展示（KPI / 筛选条 / 用量趋势 / 订阅额度 / 设备 / 矩阵 / 模型明细）+
// 底部状态区。设置区由顶栏齿轮或状态栏右键「设置…」显隐。
// 全部区块共享同一份筛选（range + hosts/tools/models/projects + metric/group），
// 数据取进程内聚合（等价 HTTP /api/*）。
import SwiftUI
import Charts
import WattsonCore

struct DashboardView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            topbar
            ScrollView {
                page
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
            statusFooter
        }
        .frame(maxWidth: .infinity)
        .frame(minWidth: 980, minHeight: 640)
        .background(dashboardBackground)
        .preferredColorScheme(nil)
        .task { await state.refreshNow() }
    }

    /// 炭黑/浅色自适应底 + 双辉光（同 web style.css 的 radial-gradient）
    private var dashboardBackground: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.accent.opacity(Theme.glowOpacity), .clear],
                           center: UnitPoint(x: 0.85, y: -0.1), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(red: 0xd9/255, green: 0xc5/255, blue: 0x89/255)
                                        .opacity(Theme.secondaryGlowOpacity), .clear],
                           center: UnitPoint(x: -0.1, y: 1.1), startRadius: 0, endRadius: 700)
        }
        .ignoresSafeArea()
    }

    // MARK: 顶栏（品牌 + 范围/指标 + 数据时间 + 刷新 + 设置齿轮）

    private var topbar: some View {
        HStack(spacing: 8) {
            brand
            rangePicker
            metricPicker
            Spacer()
            dataTime
            refreshButton
            settingsToggle
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.bg.opacity(0.82))
        .overlay(Divider().overlay(Theme.border), alignment: .bottom)
    }

    private var brand: some View {
        HStack(spacing: 6) {
            BrandMark(size: 20)
            Text("Wattson").font(.system(size: 13, weight: .semibold))
        }
    }

    private var rangePicker: some View {
        Picker("", selection: $state.filters.range) {
            ForEach(RangeOption.allCases) { r in Text(r.label).tag(r) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var metricPicker: some View {
        Picker("", selection: $state.filters.metric) {
            ForEach(MetricOption.allCases) { m in Text(m.label).tag(m) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var dataTime: some View {
        HStack(spacing: 6) {
            Circle().fill(state.snapshot.refreshing ? Theme.warn : Theme.ok).frame(width: 7, height: 7)
            Text("数据 \(Fmt.time(state.snapshot.lastSuccessAt ?? state.snapshot.fetchedAt))")
                .font(.system(size: 12.5))
                .foregroundColor(Theme.muted)
        }
    }

    private var refreshButton: some View {
        Button {
            Task { await state.refreshNow() }
        } label: {
            Label(state.refreshing ? "采集中…" : "刷新", systemImage: "arrow.clockwise")
        }
        .disabled(state.refreshing)
    }

    private var settingsToggle: some View {
        Button {
            state.requestOpenSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
        }
        .help("设置")
    }

    // MARK: 页面（单页：全部区块）

    @ViewBuilder private var page: some View {
        VStack(alignment: .leading, spacing: 14) {
            KpiSection(state: state)
            FilterBarSection(state: state)
            MainChartSection(state: state)
            PlanSection(state: state)
            HostsSection(state: state)
            MatrixSection(state: state)
            ModelsSection(state: state)
            Spacer(minLength: 8)
        }
        .padding(.bottom, 8)
    }

    // MARK: 底部状态区（status.ts）

    private var statusFooter: some View {
        HStack(spacing: 14) {
            Text("记录 \(Fmt.int(Double(state.snapshot.rows.count))) 条")
                .font(.system(size: 12))
                .foregroundColor(Theme.muted)
            if state.snapshot.errors.isEmpty {
                Text(state.snapshot.refreshing ? "解析中…" : "采集正常")
                    .font(.system(size: 12))
                    .foregroundColor(state.snapshot.refreshing ? Theme.warn : Theme.ok)
            } else {
                Text("采集异常：\(state.snapshot.errors.joined(separator: "；"))")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.err)
                    .lineLimit(1)
            }
            Text("数据口径与配置来源见「设置」").font(.system(size: 12)).foregroundColor(Theme.muted2)
            Spacer()
            if let note = state.proxyNote {
                Text(note).font(.system(size: 11)).foregroundColor(Theme.muted2)
            }
            Text("v\(WATTSON_VERSION)-native").font(.system(size: 11)).foregroundColor(Theme.muted2)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.bgSoft)
        .overlay(Divider().overlay(Theme.border), alignment: .top)
    }
}

// MARK: - 卡片容器（.card 同款）

private struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }
}

// MARK: - KPI 区（kpi.ts：5 卡 + 环比 + 全时段小字）

private struct KpiSection: View {
    @ObservedObject var state: AppState

    private static let cards: [(key: String, label: String, icon: String)] = [
        ("totalTokens", "Token 总量", "cylinder.fill"),
        ("totalCost", "估算成本", "dollarsign.circle"),
        ("calls", "调用次数", "doc.plaintext"),
        ("cacheHitRate", "缓存命中率", "bolt.fill"),
        ("activeDays", "活跃天数", "calendar"),
    ]

    var body: some View {
        let f = state.filters
        let data = state.overviewData(f)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            ForEach(Self.cards, id: \.key) { card in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: card.icon).font(.system(size: 12)).foregroundColor(Theme.accent)
                        Text(card.label).font(.system(size: 12)).foregroundColor(Theme.muted)
                    }
                    Text(Self.value(card.key, data.main))
                        .font(.system(size: 22, weight: .semibold))
                        .monospacedDigit()
                    HStack(spacing: 6) {
                        if let delta = kpiDelta(card.key, data.main, data.prev) {
                            Text(delta.text)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(delta.up ? Theme.ok : Theme.err)
                            Text("vs 上一周期").font(.system(size: 10.5)).foregroundColor(Theme.muted2)
                        }
                        if f.range != .all {
                            Text("全时段 \(Self.value(card.key, data.allTime))")
                                .font(.system(size: 10.5)).foregroundColor(Theme.muted2)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: 14, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
            }
        }
    }

    static func value(_ key: String, _ o: OverviewResult) -> String {
        switch key {
        case "totalTokens": return Fmt.tokens(o.totalTokens)
        case "totalCost": return Fmt.cost(o.totalCost)
        case "calls": return Fmt.int(o.calls)
        case "cacheHitRate": return Fmt.pct(o.cacheHitRate)
        case "activeDays": return Fmt.int(Double(o.activeDays))
        default: return "—"
        }
    }
}

// MARK: - 钻取筛选条（filters.ts：设备/工具 chips + 清除）

private struct FilterBarSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let f = state.filters
        let data = state.overviewData(f)
        if data.facetHost.isEmpty && data.facetTool.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if !data.facetHost.isEmpty {
                    Text("设备").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.muted)
                    ForEach(data.facetHost, id: \.0) { name, entry in
                        chip(facet: "hosts", name: name, tokens: entry.tokens, on: f.hosts.contains(name))
                    }
                }
                if !data.facetHost.isEmpty && !data.facetTool.isEmpty {
                    Divider().frame(height: 14).overlay(Theme.border)
                    Text("工具").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.muted)
                }
                ForEach(data.facetTool, id: \.0) { name, entry in
                    chip(facet: "tools", name: name, tokens: entry.tokens, on: f.tools.contains(name), logo: true)
                }
                if f.hasDrilldown {
                    Button("清除") {
                        state.filters.hosts = []
                        state.filters.tools = []
                    }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func chip(facet: String, name: String, tokens: Double, on: Bool, logo: Bool = false) -> some View {
        Button {
            if facet == "hosts" {
                state.filters.hosts = state.filters.hosts.contains(name)
                    ? state.filters.hosts.filter { $0 != name } : state.filters.hosts + [name]
            } else {
                state.filters.tools = state.filters.tools.contains(name)
                    ? state.filters.tools.filter { $0 != name } : state.filters.tools + [name]
            }
        } label: {
            HStack(spacing: 5) {
                if logo, let img = BrandLogo.image(for: name.lowercased()) {
                    Image(nsImage: img).resizable().scaledToFit().frame(width: 12, height: 12)
                } else {
                    Circle().fill(on ? Theme.accent : Theme.muted2).frame(width: 6, height: 6)
                }
                Text(name).font(.system(size: 11.5)).lineLimit(1)
                Text(Fmt.tokens(tokens))
                    .font(.system(size: 10.5)).foregroundColor(Theme.muted).monospacedDigit()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? Theme.accentSoft : Theme.panel2))
            .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.5) : Theme.border))
        }
        .buttonStyle(.plain)
        .foregroundColor(on ? Theme.text : Theme.muted)
    }
}

// MARK: - 用量趋势（mainchart.ts：分段维度 + 堆叠柱状图）

private struct MainChartSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let f = state.filters
        let result = state.seriesData(f)
        Card {
            HStack {
                Text("用量趋势").font(.system(size: 14, weight: .semibold))
                Spacer()
                HStack(spacing: 2) {
                    ForEach(GroupOption.allCases) { g in
                        Button(g.label) { state.filters.group = g }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: f.group == g ? .semibold : .regular))
                            .foregroundColor(f.group == g ? .white : Theme.muted)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(f.group == g ? Theme.accentSoft : Color.clear))
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel2))
            }
            SeriesChart(result: result, metric: f.metric, hourly: f.range.isHourly)
                .frame(height: 300)
        }
    }
}

/// 堆叠柱状图（ECharts 主图的 Swift Charts 等价：系列堆叠 + 图例 + 对应口径的 Y 轴格式）
struct SeriesChart: View {
    let result: SeriesResult
    let metric: MetricOption
    let hourly: Bool

    private struct Point: Identifiable {
        let id = UUID()
        let date: Date
        let key: String
        let value: Double
    }

    /// 系列顺序 = 字典序，「其他/其他*」固定排最后（配色稳定）
    private var allKeys: [String] {
        var normal = result.series.keys.filter { $0 != "其他" && $0 != "其他*" }.sorted()
        if result.series["其他"] != nil { normal.append("其他") }
        if result.series["其他*"] != nil { normal.append("其他*") }
        return normal
    }

    private var points: [Point] {
        var out: [Point] = []
        for (ti, t) in result.times.enumerated() {
            let date = Date(timeIntervalSince1970: t / 1000)
            for key in allKeys {
                if let v = result.series[key]?[ti], v != 0 {
                    out.append(Point(date: date, key: key, value: v))
                }
            }
        }
        return out
    }

    private func axisFmt(_ v: Double) -> String {
        switch metric {
        case .cost: return "$" + Fmt.tokens(v)
        case .calls: return Fmt.int(v)
        case .tokens: return Fmt.tokens(v)
        }
    }

    var body: some View {
        let keys = allKeys
        let colors = keys.enumerated().map { i, _ in Theme.palette[i % Theme.palette.count] }
        Chart {
            ForEach(points) { p in
                BarMark(
                    x: .value("时间", p.date, unit: hourly ? .hour : .day),
                    y: .value(metric.label, p.value)
                )
                .foregroundStyle(by: .value("系列", p.key))
                .cornerRadius(1.5)
            }
        }
        .chartForegroundStyleScale(domain: keys, range: colors)
        .chartLegend(keys.count > 1 ? .visible : .hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { axis in
                AxisGridLine().foregroundStyle(Theme.borderStrong)
                AxisValueLabel {
                    if let v = axis.as(Double.self) {
                        Text(axisFmt(v)).font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 8)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: hourly ? .dateTime.month().day().hour() : .dateTime.month().day())
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            }
        }
        .chartPlotStyle { plot in
            plot.background(Theme.bgSoft)
        }
    }
}

// MARK: - 订阅额度区（plan.ts：卡片网格 + 剩余口径窗口条）

private struct PlanSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let accounts = state.quota.accounts
        let cards = accounts.filter { $0.available || ($0.unavailableReason != "no_credentials" && $0.unavailableReason != "loading") }
        if !cards.isEmpty {
            Text("订阅额度").font(.system(size: 14, weight: .semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], spacing: 12) {
                ForEach(cards, id: \.self) { PlanCard(account: $0) }
            }
        }
    }
}

struct PlanCard: View {
    let account: QuotaAccount

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !account.available {
                Text(account.label).font(.system(size: 12, weight: .semibold))
                Text("未能读取（\(account.unavailableReason ?? "unknown")\(account.error.map { "：\($0)" } ?? "")）")
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.muted)
            } else {
                HStack(spacing: 8) {
                    BrandLogo(kind: account.kind.rawValue, size: 28)
                    Text(QuotaShort.kind[account.kind.rawValue] ?? account.label)
                        .font(.system(size: 13, weight: .semibold))
                    if let plan = account.planName,
                       plan != (QuotaShort.kind[account.kind.rawValue] ?? account.label) {
                        Text(plan).font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .background(Capsule().fill(Theme.accent))
                            .lineLimit(1)
                    }
                    if let rc = account.resetCredits, rc > 0 {
                        Text("重置卡 ×\(Int(rc))").font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .background(Capsule().fill(Theme.warn))
                    }
                    Spacer()
                }
                if account.windows.isEmpty {
                    Text("套餐生效中，暂无额度窗口数据").font(.system(size: 11.5)).foregroundColor(Theme.muted)
                } else {
                    ForEach(account.windows, id: \.key) { w in
                        windowRow(w)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
    }

    private func windowRow(_ w: QuotaWindow) -> some View {
        // 剩余口径（plan.ts windowRow）：绝对值向上取整；纯百分比 100-已用%
        let hasAbs = w.total != nil
        let remainingAbs = hasAbs ? (w.remaining ?? max(0, (w.total ?? 0) - (w.used ?? 0))) : nil
        let remainPct: Double = remainingAbs != nil && (w.total ?? 0) > 0
            ? ceil(min(100, max(0, remainingAbs! / (w.total ?? 1) * 100)))
            : 100 - min(100, max(0, w.percentage ?? w.usedPercent ?? 0))
        let barColor = remainPct <= 10 ? Theme.err : remainPct <= 30 ? Theme.warn : Theme.accent
        let reset = Fmt.reset(w.nextResetAt)
        let nums = remainingAbs != nil
            ? "剩 \(Int(remainPct))% · \(Fmt.int(remainingAbs!))/\(Fmt.int(w.total ?? 0))"
            : "剩 \(Int(remainPct))%"
        return HStack(spacing: 8) {
            Text(QuotaShort.window[w.key] ?? w.label)
                .font(.system(size: 11.5)).foregroundColor(Theme.muted)
                .frame(width: 58, alignment: .leading).lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panel2)
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * min(100, max(0, remainPct)) / 100)
                }
            }
            .frame(height: 6)
            HStack(spacing: 4) {
                Text(nums).monospacedDigit()
                if !reset.isEmpty {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text(reset)
                }
            }
            .font(.system(size: 10.5, weight: remainPct <= 30 ? .semibold : .regular))
            .foregroundColor(remainPct <= 30 ? Theme.err : Theme.muted)
            .frame(alignment: .trailing)
            .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 设备区（hosts.ts：份额卡 + 设备×时间图）

private struct HostsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let f = state.filters
        let data = state.overviewData(f)
        let hosts = data.facetHost.filter { $0.1.tokens > 0 }
        if hosts.isEmpty {
            EmptyView()
        } else {
            let total = hosts.reduce(0.0) { $0 + $1.1.tokens }
            VStack(alignment: .leading, spacing: 14) {
                Text("设备").font(.system(size: 14, weight: .semibold))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(hosts, id: \.0) { name, entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Circle().fill(Theme.accent).frame(width: 8, height: 8)
                                Text(name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Spacer()
                                Text(String(format: "%.1f%%", entry.tokens / total * 100))
                                    .font(.system(size: 12)).foregroundColor(Theme.muted).monospacedDigit()
                            }
                            Text(Fmt.tokens(entry.tokens)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
                            Text("\(Fmt.cost(entry.cost)) · \(Fmt.int(entry.calls)) 次调用")
                                .font(.system(size: 11.5)).foregroundColor(Theme.muted).monospacedDigit()
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.panel2)
                                    Capsule().fill(Theme.accent)
                                        .frame(width: geo.size.width * entry.tokens / total)
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
                    }
                }
                Card {
                    HStack {
                        Text("设备 × 时间（\(f.metric.label)）").font(.system(size: 14, weight: .semibold))
                        Spacer()
                    }
                    SeriesChart(result: state.seriesData(f, group: .host), metric: f.metric, hourly: f.range.isHourly)
                        .frame(height: 240)
                }
            }
        }
    }
}

// MARK: - 矩阵 + 模型明细

private struct MatrixSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let (rowsKey, m) = state.matrixData(state.filters)
        Card(title: "矩阵（\(rowsKey) × model，token）") {
            if m.rowKeys.isEmpty {
                Text("暂无数据").font(.system(size: 12)).foregroundColor(Theme.muted)
            } else {
                let max = m.values.flatMap { $0 }.compactMap { $0 }.max() ?? 1
                ScrollView(.horizontal, showsIndicators: false) {
                    Grid(alignment: .leading, horizontalSpacing: 1, verticalSpacing: 1) {
                        GridRow {
                            Text("").frame(width: 90, alignment: .leading)
                            ForEach(m.colKeys, id: \.self) { c in
                                Text(c).font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(Theme.muted).lineLimit(1)
                                    .frame(width: 74)
                            }
                        }
                        ForEach(Array(m.rowKeys.enumerated()), id: \.offset) { i, r in
                            GridRow {
                                Text(r).font(.system(size: 11, weight: .semibold))
                                    .frame(width: 90, alignment: .leading).lineLimit(1)
                                ForEach(Array(m.colKeys.enumerated()), id: \.offset) { j, _ in
                                    let v = m.values[i][j]
                                    Text(v.map { Fmt.tokens($0) } ?? "")
                                        .font(.system(size: 11)).monospacedDigit()
                                        .foregroundColor(v != nil ? Theme.text : .clear)
                                        .frame(width: 74, height: 26)
                                        .background(v.map { Theme.accent.opacity(0.08 + 0.85 * $0 / max) } ?? .clear)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct ModelsSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let rows = state.modelsData(state.filters)
        Card(title: "模型明细") {
            if rows.isEmpty {
                Text("暂无数据").font(.system(size: 12)).foregroundColor(Theme.muted)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        ForEach(["模型", "调用", "输入", "输出", "推理", "缓存读", "缓存写", "成本"], id: \.self) { h in
                            Text(h).font(.system(size: 11.5, weight: .semibold)).foregroundColor(Theme.muted)
                                .frame(width: h == "模型" ? 170 : 70, alignment: h == "模型" ? .leading : .trailing)
                        }
                    }
                    Divider().overlay(Theme.border)
                    ForEach(rows, id: \.model) { e in
                        GridRow {
                            Text(e.model).font(.system(size: 12)).lineLimit(1)
                                .frame(width: 170, alignment: .leading)
                            Text(Fmt.int(e.calls)).font(.system(size: 12)).monospacedDigit()
                            Text(Fmt.tokens(e.tin)).font(.system(size: 12)).monospacedDigit()
                            Text(Fmt.tokens(e.tout)).font(.system(size: 12)).monospacedDigit()
                            Text(Fmt.tokens(e.treason)).font(.system(size: 12)).monospacedDigit()
                            Text(Fmt.tokens(e.tcacheRead)).font(.system(size: 12)).monospacedDigit()
                            Text(Fmt.tokens(e.tcacheWrite)).font(.system(size: 12)).monospacedDigit()
                            Text(Fmt.cost(e.cost)).font(.system(size: 12)).monospacedDigit()
                        }
                    }
                }
            }
        }
    }
}
