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
        .task { await state.refreshIfStale() }
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
        .wattsonCard()
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
                .wattsonCard(padding: 12)
            }
        }
        // 估算口径必须可见：成本里有「解析时未定价、事后按价目表重估」的部分，
        // 它与已存成本混在同一个数字里，但可信度不同（之前只算不展示）
        if data.main.estimatedCost > 0 {
            Text("成本含估算部分 \(Fmt.cost(data.main.estimatedCost))（未存储成本的行按内嵌价目表重估）")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.muted2)
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
            // 流式折行：chip 一行放不下时整齐换到第二行（原单行 HStack 会挤错行）
            FlowLegend(spacing: 6, lineSpacing: 6) {
                if !data.facetHost.isEmpty {
                    groupLabel("设备")
                    ForEach(data.facetHost, id: \.0) { name, entry in
                        chip(facet: "hosts", name: name, tokens: entry.tokens, on: f.hosts.contains(name))
                    }
                }
                if !data.facetHost.isEmpty && !data.facetTool.isEmpty {
                    groupLabel("工具")
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
                    .font(.system(size: 11.5, weight: .medium))
                }
            }
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(Theme.muted)
            .padding(.trailing, 2)
            .frame(height: 22)  // 与 chip 行高一致，折行后基线整齐
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

/// 堆叠柱状图（ECharts 主图的 Swift Charts 等价）：
/// 分类轴（每时间桶一个类目，柱与标签同心）+ hover 明细 tooltip +
/// 可点击图例开关系列。
struct SeriesChart: View {
    let result: SeriesResult
    let metric: MetricOption
    let hourly: Bool

    /// 用户手动隐藏的系列（图例点击开关；原 ECharts legend.selected）
    @State private var hiddenKeys: Set<String> = []
    /// 当前 hover 的桶索引（nil = 无提示框）
    @State private var hoverIndex: Int?
    /// hover 桶中心的 plot 区 x（tooltip 定位用）
    @State private var hoverX: CGFloat = 0
    /// plot 区相对整个 Chart 的偏移（换算坐标用）
    @State private var plotOriginX: CGFloat = 0

    /// 系列顺序 = 字典序，「其他/其他*」固定排最后（配色稳定）
    private var allKeys: [String] {
        var normal = result.series.keys.filter { $0 != "其他" && $0 != "其他*" }.sorted()
        if result.series["其他"] != nil { normal.append("其他") }
        if result.series["其他*"] != nil { normal.append("其他*") }
        return normal
    }

    private var visibleKeys: [String] { allKeys.filter { !hiddenKeys.contains($0) } }

    private func color(_ key: String) -> Color {
        guard let idx = allKeys.firstIndex(of: key) else { return Theme.accent }
        return Theme.palette[idx % Theme.palette.count]
    }

    private func valueFmt(_ v: Double) -> String {
        switch metric {
        case .cost: return Fmt.cost(v)
        case .calls: return Fmt.int(v)
        case .tokens: return Fmt.tokens(v)
        }
    }

    private func axisFmt(_ v: Double) -> String {
        switch metric {
        case .cost: return "$" + Fmt.tokens(v)
        case .calls: return Fmt.int(v)
        case .tokens: return Fmt.tokens(v)
        }
    }

    /// 时间桶 → 分类轴类目标签（日桶 MM-dd，跨年补 yy-；小时桶 MM-dd HH时）
    private var bucketLabels: [String] {
        guard let first = result.times.first, let last = result.times.last else { return [] }
        let cal = Calendar.current
        let crossesYear = cal.component(.year, from: Date(timeIntervalSince1970: first / 1000))
            != cal.component(.year, from: Date(timeIntervalSince1970: last / 1000))
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = hourly ? "MM-dd HH时" : (crossesYear ? "yy-MM-dd" : "MM-dd")
        return result.times.map { f.string(from: Date(timeIntervalSince1970: $0 / 1000)) }
    }

    /// 轴标签抽稀：最多约 8 个（对应原版 hideOverlap），柱子仍全部绘制
    private var axisLabelSubset: [String] {
        let labels = bucketLabels
        guard labels.count > 9 else { return labels }
        let step = Int((Double(labels.count) / 8.0).rounded(.up))
        return labels.enumerated().compactMap { $0.offset % step == 0 ? $0.element : nil }
    }

    private struct Bar: Identifiable {
        let id: String        // 桶索引+系列名：body 重算时保持稳定
        let label: String     // 分类轴类目（时间桶标签）
        let key: String
        let value: Double
    }

    private var bars: [Bar] {
        let labels = bucketLabels
        var out: [Bar] = []
        for (ti, _) in result.times.enumerated() where ti < labels.count {
            for key in visibleKeys {
                if let v = result.series[key]?[ti], v != 0 {
                    out.append(Bar(id: "\(ti)|\(key)", label: labels[ti], key: key, value: v))
                }
            }
        }
        return out
    }

    /// hover 桶内的明细行（非零系列按值降序；原 tooltipHtml 口径）
    private var hoverRows: [(key: String, value: Double)] {
        guard let i = hoverIndex else { return [] }
        return visibleKeys.compactMap { key in
            guard let v = result.series[key]?[i], v != 0 else { return nil }
            return (key, v)
        }.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(spacing: 6) {
            if allKeys.count > 1 { legend }
            chart
        }
    }

    // MARK: 图例（点击开关系列）

    private var legend: some View {
        FlowLegend(spacing: 6, lineSpacing: 5) {
            ForEach(allKeys, id: \.self) { key in
                Button {
                    if hiddenKeys.contains(key) {
                        hiddenKeys.remove(key)
                    } else if hiddenKeys.count < allKeys.count - 1 {
                        hiddenKeys.insert(key)  // 至少保留一个系列
                    } else {
                        hiddenKeys.removeAll()  // 点最后一个 = 全部恢复
                    }
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(hiddenKeys.contains(key) ? Theme.muted2.opacity(0.4) : color(key))
                            .frame(width: 8, height: 8)
                        Text(key)
                            .font(.system(size: 11))
                            .foregroundStyle(hiddenKeys.contains(key) ? Theme.muted2 : Theme.muted)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(hiddenKeys.contains(key) ? Color.clear : Theme.panel2))
                    .overlay(Capsule().strokeBorder(Theme.border, lineWidth: hiddenKeys.contains(key) ? 1 : 0))
                }
                .buttonStyle(.plain)
                .help(hiddenKeys.contains(key) ? "显示 \(key)" : "隐藏 \(key)")
            }
        }
    }

    // MARK: 图表

    private var chart: some View {
        let labels = bucketLabels
        let keys = visibleKeys
        return Chart {
            ForEach(bars) { bar in
                BarMark(x: .value("时间", bar.label), y: .value(metric.label, bar.value))
                    // foregroundStyle(by:) 同时是「按系列堆叠」的语义信号：
                    // 换成 foregroundStyle(color:) 会让同类目内的柱被并排分组而偏离中心
                    .foregroundStyle(by: .value("系列", bar.key))
                    .cornerRadius(2)
            }
        }
        .chartForegroundStyleScale(domain: keys, range: keys.map(color))
        .chartLegend(.hidden)
        // 类目域显式声明：空桶占位、顺序即时间顺序（不能用 0 高占位柱凑类目，
        // 那会触发同类目并排分组）
        .chartXScale(domain: labels)
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
            AxisMarks(values: axisLabelSubset) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel()
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            }
        }
        .chartPlotStyle { plot in
            plot.background(Theme.bgSoft)
        }
        // hover 层：用 chartOverlay 提供 plot 区坐标系，命中区铺满整个 Chart
        // （contentShape 保证透明区域也能接收指针事件）
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plotFrame = geo[proxy.plotAreaFrame]
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            // proxy.position(forX:) 返回 plot 区内部坐标，而命中层的局部
                            // 坐标从 Chart 左上角起算（含约 50pt Y 轴）——必须换算，
                            // 否则命中会整体右移约 1.5 个时间桶
                            plotOriginX = plotFrame.minX
                            hoverAt(x: location.x - plotFrame.minX, proxy: proxy)
                        case .ended:
                            hoverIndex = nil
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        if hoverIndex != nil, !hoverRows.isEmpty {
                            tooltip
                                .position(x: min(max(hoverX + plotOriginX, tooltipWidth / 2 + 8),
                                                 geo.size.width - tooltipWidth / 2 - 8),
                                          y: tooltipHeight / 2 + 6)
                        }
                    }
            }
        }
    }

    /// 取最近类目（按各类目的 plot 区屏幕 x），并记录桶中心用于 tooltip 定位
    private func hoverAt(x: CGFloat, proxy: ChartProxy) {
        let labels = bucketLabels
        guard !labels.isEmpty else { return }
        var bestIdx: Int?
        var bestDist = CGFloat.greatestFiniteMagnitude
        var bestX: CGFloat = x
        for (i, label) in labels.enumerated() {
            guard let cx = proxy.position(forX: label) else { continue }
            let d = abs(cx - x)
            if d < bestDist {
                bestDist = d
                bestIdx = i
                bestX = cx
            }
        }
        hoverIndex = bestIdx
        hoverX = bestX
    }

    private var tooltipWidth: CGFloat { 300 }
    private var tooltipHeight: CGFloat {
        CGFloat(min(hoverRows.count, 9) * 20 + 52)
    }

    /// hover 明细卡：桶名 + 逐系列行（色点 名称 值）+ 合计（多系列时）
    private var tooltip: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let i = hoverIndex, i < bucketLabels.count {
                Text(bucketLabels[i])
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            ForEach(hoverRows.prefix(8), id: \.key) { row in
                HStack(spacing: 6) {
                    Circle().fill(color(row.key)).frame(width: 7, height: 7)
                    Text(row.key).lineLimit(1).foregroundStyle(Theme.muted)
                    Spacer(minLength: 6)
                    Text(valueFmt(row.value)).monospacedDigit().foregroundStyle(Theme.text)
                }
                .font(.system(size: 11))
            }
            if hoverRows.count > 8 {
                Text("还有 \(hoverRows.count - 8) 项…")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.muted2)
            }
            if hoverRows.count > 1 {
                Divider().overlay(Theme.border)
                HStack {
                    Text("合计").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(valueFmt(hoverRows.reduce(0) { $0 + $1.value }))
                        .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.panel)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
        .allowsHitTesting(false)
    }
}

// MARK: - 订阅额度区（plan.ts：卡片网格 + 剩余口径窗口条）

private struct PlanSection: View {
    @ObservedObject var state: AppState

    var body: some View {
        let accounts = state.quota.accounts
        let cards = accounts.filter { $0.available || ($0.unavailableReason != "no_credentials" && $0.unavailableReason != "loading") }
        if !cards.isEmpty {
            // 统一卡片高度：按最大窗口数定行槽位，不足的卡片补隐形行
            // （有的 provider 只给周额度，1 行卡会明显矮于 5小时+周 的 2 行卡）
            let rowSlots = max(1, cards.map(\.windows.count).max() ?? 1)
            Text("订阅额度").font(.system(size: 14, weight: .semibold))
            // 固定 2 个弹性列（一行 2 个）。不要用 adaptive：卡片固有最小宽约 382pt
            // （标签 56 + 进度条 132 + 数字 150 + 行内间距 16 + 内边距 28），窗口 ≥980 时
            // adaptive(minimum: 300) 会排出 3 列（列宽仅约 305），卡片内容溢出轨道被邻卡压住。
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
                      spacing: 12) {
                ForEach(cards, id: \.self) { PlanCard(account: $0, rowSlots: rowSlots) }
            }
        }
    }
}

struct PlanCard: View {
    let account: QuotaAccount
    /// 行槽位数（订阅额度区内所有卡片的最大窗口数）：窗口不足的卡片补隐形行，
    /// 保证整片订阅框等高；「未读到」「套餐生效中」也各占一个槽位
    var rowSlots: Int = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if account.available && !account.windows.isEmpty {
                ForEach(account.windows, id: \.key) { windowRow($0) }
                fillerSlots(rowSlots - account.windows.count)
            } else {
                slotText(account.available
                         ? "套餐生效中，暂无额度窗口数据"
                         : "未能读取（\(account.unavailableReason ?? "unknown")\(account.error.map { "：\($0)" } ?? "")）")
                fillerSlots(rowSlots - 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .wattsonCard()
    }

    /// 卡片头部：两类卡片（正常 / 未读到）结构一致，高度才对得齐
    private var header: some View {
        HStack(spacing: 8) {
            BrandLogo(kind: account.kind.rawValue, size: 28)
            Text(QuotaShort.kind[account.kind.rawValue] ?? account.label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(account.available ? Theme.text : Theme.muted)
            if account.available,
               let plan = account.planName,
               plan != (QuotaShort.kind[account.kind.rawValue] ?? account.label) {
                Text(plan).font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(Theme.accent))
                    .lineLimit(1)
            }
            if account.available, let rc = account.resetCredits, rc > 0 {
                Text("重置卡 ×\(Int(rc))").font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(Theme.warn))
            }
            Spacer()
        }
    }

    /// 补齐高度用的隐形行：复用 windowRow 结构，占位高度与真实行完全一致
    @ViewBuilder private func fillerSlots(_ count: Int) -> some View {
        if count > 0 {
            ForEach(0..<count, id: \.self) { i in
                windowRow(QuotaWindow(key: "slot-\(i)", label: " ")).hidden()
            }
        }
    }

    /// 无窗口数据时的说明文字：套在隐形窗口行里，使该槽位与真实窗口行等高
    private func slotText(_ text: String) -> some View {
        ZStack(alignment: .leading) {
            windowRow(QuotaWindow(key: "slot-text", label: " ")).hidden()
            Text(text)
                .font(.system(size: 11.5))
                .foregroundColor(Theme.muted)
                .lineLimit(2)
        }
    }

    /// 窗口行：三列严格对齐（标签 60 / 进度条弹性 / 数字 168 右对齐），
    /// 同一卡片内多行进度条起点终点上下一致
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
                .frame(width: 56, alignment: .leading).lineLimit(1)
            // 进度条固定宽度：卡片内多行（5小时/周）起止位置严格一致
            quotaBar(fraction: remainPct / 100, color: barColor)
                .frame(width: 132)
            VStack(alignment: .trailing, spacing: 1) {
                Text(nums).monospacedDigit()
                    .font(.system(size: 10.5, weight: remainPct <= 30 ? .semibold : .regular))
                    .foregroundStyle(remainPct <= 30 ? Theme.err : Theme.muted)
                    .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 3) {
                    Image(systemName: "clock").font(.system(size: 8.5))
                    Text(reset.isEmpty ? " " : reset)  // 空占位保持两行基线对齐
                }
                .font(.system(size: 9.5))
                .foregroundStyle(Theme.muted2)
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(width: 150, alignment: .trailing)  // 数字列定宽：多行右缘对齐
        }
        .padding(.vertical, 3)
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

/// 流式折行布局（Layout 协议）：子项按内容自适应宽度，超行自动折到下一行。
/// 注意：必须按行保序累加 x 坐标；用字典存行会让同排子项顺序错乱并堆叠到同一点。
private struct FlowLegend: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private struct Item {
        let index: Int
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 320
        let lines = arrange(maxWidth: maxWidth, subviews: subviews)
        let width = lines.map(\.width).max() ?? 0
        let height = CGFloat(lines.count) * lineHeight + CGFloat(max(0, lines.count - 1)) * lineSpacing
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let lines = arrange(maxWidth: bounds.width, subviews: subviews)
        for (li, line) in lines.enumerated() {
            var x = bounds.minX
            let y = bounds.minY + CGFloat(li) * (lineHeight + lineSpacing)
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: x, y: y),
                                           anchor: .topLeading,
                                           proposal: ProposedViewSize(item.size))
                x += item.size.width + spacing
            }
        }
    }

    private var lineHeight: CGFloat { 22 }

    private struct Line {
        var items: [Item] = []
        var width: CGFloat = 0
    }

    /// 按可用宽度分行（保序；行宽含项间间距，不含行尾多余间距）
    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var lines: [Line] = [Line()]
        var x: CGFloat = 0
        for (i, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let needed = (x > 0 ? spacing : 0) + size.width
            if x > 0, x + needed > maxWidth {
                lines.append(Line())
                x = 0
            }
            let add = (x > 0 ? spacing : 0) + size.width
            lines[lines.count - 1].items.append(Item(index: i, size: size))
            lines[lines.count - 1].width += add
            x += add
        }
        return lines
    }
}
