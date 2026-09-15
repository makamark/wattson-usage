// PopupView.swift — 状态栏小窗（app/src/popup/index.html 的 1:1 移植）。
// 结构：头部（品牌 + 范围切换 + 状态 chips）→ 范围标题 → 2×2 KPI（环比）→
// 全时段小字（仅 24h）→ 订阅额度（剩余口径，≤30% 标红）→ 明细折叠（按工具/按设备，
// 过滤零值、按用量降序、保留合计）→ 错误框；底部「刷新数据 / 打开完整看板」。
import SwiftUI
import WattsonCore

struct PopupView: View {
    @ObservedObject var state: AppState
    let openDashboard: () -> Void
    @AppStorage("wattson.popup.detail") private var detailOpen = false

    /// popup KPI 四卡（popup.html KPI_CARDS）：SF Symbol 近似原内联小图标
    private static let kpiCards: [(key: String, label: String, icon: String)] = [
        ("totalTokens", "Token 总量", "cylinder.fill"),
        ("totalCost", "估算成本", "dollarsign.circle"),
        ("calls", "调用次数", "doc.plaintext"),
        ("cacheHitRate", "缓存命中", "bolt.fill"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if state.snapshot.rows.isEmpty {
                        placeholder
                    } else {
                        content
                    }
                    if !state.snapshot.errors.isEmpty {
                        errbox
                    }
                }
                .padding(.horizontal, 13)
                .padding(.top, 4)
                .padding(.bottom, 8)
            }
            footer
        }
        // MenuBarExtra window 态按内容理想高度开窗：ScrollView 理想高度为 0，
        // 不给定固定高度窗口会塌缩成只剩头尾
        .frame(width: 384, height: 500)
        .background(popupBackground.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await state.pollQuotaNow() }
    }

    // MARK: 背景（popup 同款：炭黑底 + 右上角电表绿辉光）

    private var popupBackground: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.9, y: -0.2), startRadius: 10, endRadius: 420)
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                BrandMark(size: 22)
                Text("Wattson").font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 4)
            Picker("", selection: $state.popupRange) {
                ForEach([RangeOption.today, .h24, .d7, .d30]) { r in
                    Text(r.popupShortLabel).tag(r)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
            chips
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    @ViewBuilder private var chips: some View {
        HStack(spacing: 5) {
            chip(text: "数据 \(Fmt.clock(state.snapshot.lastSuccessAt ?? state.snapshot.fetchedAt))" +
                (state.snapshot.rows.isEmpty ? "" : " · \(Fmt.int(Double(state.snapshot.rows.count))) 条"))
            if state.snapshot.refreshing {
                chip(text: "解析中…", live: true)
            }
        }
    }

    private func chip(text: String, live: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundColor(live ? Theme.ok : Theme.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 1)
            .background(Capsule().fill(Theme.panel2))
            .overlay(Capsule().strokeBorder(live ? Theme.ok.opacity(0.35) : Theme.border))
            .lineLimit(1)
    }

    // MARK: 主体

    private var placeholder: some View {
        VStack(spacing: 8) {
            Text("暂无用量数据").font(.system(size: 15, weight: .medium))
            Text("本机 AI 工具产生用量后自动出现").font(.caption).foregroundColor(Theme.muted)
        }
        .foregroundColor(Theme.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var content: some View {
        let f = DashboardFilters(range: state.popupRange)
        let data = state.overviewData(f)
        return VStack(alignment: .leading, spacing: 0) {
            Text(state.popupRange.popupTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.muted)
                .kerning(0.9)
                .padding(.top, 10)
                .padding(.bottom, 6)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 7), GridItem(.flexible(), spacing: 7)], spacing: 7) {
                ForEach(Self.kpiCards, id: \.key) { card in
                    kpiCard(icon: card.icon, label: card.label,
                            value: popupKpiValue(card.key, data.main),
                            delta: kpiDelta(card.key, data.main, data.prev))
                }
            }
            if state.popupRange == .h24 {
                Text("全时段：\(Fmt.tokens(data.allTime.totalTokens)) · \(Fmt.cost(data.allTime.totalCost)) · 活跃 \(data.allTime.activeDays) 天")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.muted)
                    .padding(.top, 6)
            }
            planSection
            detailSection
            Spacer(minLength: 2)
        }
    }

    private func popupKpiValue(_ key: String, _ o: OverviewResult) -> String {
        switch key {
        case "totalTokens": return Fmt.tokens(o.totalTokens)
        case "totalCost": return Fmt.cost(o.totalCost)
        case "calls": return Fmt.int(o.calls)
        case "cacheHitRate": return Fmt.pct(o.cacheHitRate)
        default: return "—"
        }
    }

    private func kpiCard(icon: String, label: String, value: String, delta: KpiDelta?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(Theme.accent)
                Text(label).font(.system(size: 10.5)).foregroundColor(Theme.muted)
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
            HStack(spacing: 5) {
                if let delta {
                    Text(delta.text)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(delta.up ? Theme.ok : Theme.err)
                }
            }
            .frame(height: 14, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
    }

    // MARK: 订阅额度（剩余口径，≤30% 标红）

    @ViewBuilder private var planSection: some View {
        let accounts = state.quota.accounts
            .filter { $0.available && !$0.windows.isEmpty }
        if !accounts.isEmpty {
            Text("订阅额度")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Theme.muted)
                .kerning(0.9)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ForEach(accounts, id: \.self) { account in
                popupAccountCard(account)
            }
        }
    }

    private func popupAccountCard(_ a: QuotaAccount) -> some View {
        let shortName = QuotaShort.kind[a.kind.rawValue] ?? a.label
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                BrandLogo(kind: a.kind.rawValue, size: 20)
                Text(shortName)
                    .font(.system(size: 12, weight: .semibold))
                if let plan = a.planName, plan != shortName {
                    Text(plan)
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0xd5/255, green: 0xe5/255, blue: 0xde/255))
                        .padding(.horizontal, 7)
                        .background(Capsule().fill(Theme.accentSoft))
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.4)))
                        .lineLimit(1)
                }
                if let rc = a.resetCredits, rc > 0 {
                    Text("重置卡 ×\(Int(rc))")
                        .font(.system(size: 10))
                        .foregroundColor(Color(red: 0xf0/255, green: 0xd9/255, blue: 0xac/255))
                        .padding(.horizontal, 7)
                        .background(Capsule().fill(Theme.warn.opacity(0.12)))
                        .overlay(Capsule().strokeBorder(Theme.warn.opacity(0.4)))
                }
                Spacer()
            }
            ForEach(a.windows, id: \.key) { w in
                popupWindowRow(w)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))
        .padding(.bottom, 7)
    }

    private func popupWindowRow(_ w: QuotaWindow) -> some View {
        // 剩余口径（对齐官方展示）：绝对值取 remaining/total 向上取整；纯百分比用 100-已用%
        let hasAbs = w.total != nil
        let remainingAbs = hasAbs ? (w.remaining ?? max(0, (w.total ?? 0) - (w.used ?? 0))) : nil
        let remainPct: Double = remainingAbs != nil && (w.total ?? 0) > 0
            ? ceil(min(100, max(0, remainingAbs! / (w.total ?? 1) * 100)))
            : 100 - min(100, max(0, w.percentage ?? w.usedPercent ?? 0))
        let barColor = remainPct <= 10 ? Theme.err : remainPct <= 30 ? Theme.warn : Theme.accent
        let reset = Fmt.resetPopup(w.nextResetAt)
        let nums = "剩 \(Int(remainPct))%" + (reset.isEmpty ? "" : " · \(reset)")
        return HStack(spacing: 7) {
            Text(QuotaShort.window[w.key] ?? w.label)
                .font(.system(size: 11))
                .foregroundColor(Theme.muted)
                .frame(width: 46, alignment: .leading)
                .lineLimit(1)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.panel2)
                    Capsule().fill(barColor)
                        .frame(width: geo.size.width * min(100, max(0, remainPct)) / 100)
                }
            }
            .frame(height: 6)
            Text(nums)
                .font(.system(size: 10.5, weight: remainPct <= 30 ? .semibold : .regular))
                .foregroundColor(remainPct <= 30 ? Theme.err : Theme.muted)
                .monospacedDigit()
                .frame(width: 92, alignment: .trailing)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    // MARK: 明细（按工具 / 按设备，过滤零值、降序、保留合计）

    @ViewBuilder private var detailSection: some View {
        let f = DashboardFilters(range: state.popupRange)
        let data = state.overviewData(f)
        let byTool = state.breakdown(data.main.byTool)
        let byHost = state.breakdown(data.main.byHost)
        if !byTool.isEmpty || !byHost.isEmpty {
            DisclosureGroup(isExpanded: $detailOpen) {
                breakdown("按工具", byTool)
                breakdown("按设备", byHost)
            } label: {
                Text("明细")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Theme.muted)
                    .kerning(0.9)
            }
            .padding(.top, 12)
        }
    }

    @ViewBuilder private func breakdown(_ title: String, _ rows: [(name: String, tokens: Double, cost: Double?)]) -> some View {
        if !rows.isEmpty {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Theme.muted)
                .padding(.top, 8)
                .padding(.bottom, 2)
            let maxTk = rows[0].tokens
            let total = rows.reduce(0.0) { $0 + $1.tokens }
            let totalCost = rows.reduce(0.0) { $0 + ($1.cost ?? 0) }
            let anyCost = rows.contains { $0.cost != nil }
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(spacing: 8) {
                    Text(row.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .frame(width: 86, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.panel2)
                            Capsule().fill(Theme.accent.opacity(i == 0 ? 1 : max(0.45, 1 - Double(i) * 0.12)))
                                .frame(width: geo.size.width * row.tokens / maxTk)
                        }
                    }
                    .frame(height: 6)
                    Text(Fmt.tokens(row.tokens))
                        .font(.system(size: 12)).monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    Text(Fmt.cost(row.cost))
                        .font(.system(size: 12)).foregroundColor(Theme.muted).monospacedDigit()
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 8) {
                Text("合计").font(.system(size: 12)).foregroundColor(Theme.muted)
                    .frame(width: 86, alignment: .leading)
                Spacer()
                Text(Fmt.tokens(total)).font(.system(size: 12)).monospacedDigit()
                    .frame(width: 52, alignment: .trailing)
                Text(anyCost ? Fmt.cost(totalCost) : "—").font(.system(size: 12)).monospacedDigit()
                    .frame(width: 58, alignment: .trailing)
            }
            .padding(.top, 5)
        }
    }

    private var errbox: some View {
        Text(state.snapshot.errors.joined(separator: "\n"))
            .font(.system(size: 12))
            .foregroundColor(Theme.err)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.err.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.err.opacity(0.3)))
            .padding(.top, 10)
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                Task {
                    await state.refreshNow()
                    await state.pollQuotaNow()
                }
            } label: {
                Text(state.refreshing ? "采集中…" : "刷新数据")
            }
            .buttonStyle(PanelButtonStyle())
            .disabled(state.refreshing)
            Button {
                openDashboard()
            } label: {
                Text("打开完整看板")
            }
            .buttonStyle(AccentButtonStyle())
        }
        .controlSize(.regular)
        .padding(10)
        .background(Theme.bgSoft)
    }
}

/// 品牌标（Token Meter 图标缩略）
struct BrandMark: View {
    var size: CGFloat = 22

    var body: some View {
        if let img = BrandMark.image {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.32))
        } else {
            Text("⚡").font(.system(size: size * 0.7)).frame(width: size, height: size)
        }
    }

    static var image: NSImage? {
        if let cached = _image { return cached }
        guard let url = Bundle.module.url(forResource: "brand", withExtension: "png", subdirectory: "Resources"),
              let img = NSImage(contentsOf: url) else { return nil }
        _image = img
        return img
    }

    private static var _image: NSImage?
}

extension RangeOption {
    /// popup 顶部切换的短标签（原 select：今日/24h/7天/30天）
    var popupShortLabel: String {
        switch self {
        case .today: return "今日"
        case .h24: return "24h"
        case .d7: return "7天"
        case .d30: return "30天"
        case .all: return "全部"
        }
    }
}


// MARK: - 小窗按钮样式（原 popup：panel-2 底 + 描边 / 主按钮 accent 实底）

struct PanelButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5))
            .foregroundColor(configuration.isPressed ? Theme.muted : Theme.text)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? Theme.panel3 : Theme.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(configuration.isPressed ? Theme.borderStrong : Theme.border))
    }
}

struct AccentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundColor(.white)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(configuration.isPressed ? Color(red: 0x63/255, green: 0xb2/255, blue: 0x9c/255) : Theme.accent))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent))
    }
}
