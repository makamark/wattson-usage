// Theme.swift — Wattson 主题：跟随系统外观的动态配色（浅色 Apple 风 / 深色炭黑仪表风）
// 与格式化工具（与 web/src/format.ts 同口径）。
// 浅色 = Apple 风（白卡 + 灰底 + 品牌电表绿原始值 #447E72）；
// 深色 = 原 web/src/style.css 的炭黑仪表风（accent 提亮为 #57a48f）。
import SwiftUI
import WattsonCore

private func dynamicColor(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

enum Theme {
    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        dynamicColor(rgb(light), rgb(dark))
    }

    static let bg = dynamic(0xf5f5f7, 0x14181a)
    static let bgSoft = dynamic(0xeeeeef, 0x191e20)
    static let panel = dynamic(0xffffff, 0x22282a)
    static let panel2 = dynamic(0xf0f0f2, 0x2a3134)
    static let panel3 = dynamic(0xe5e5e7, 0x333b3e)
    static var border: Color { dynamicColor(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.07)) }
    static var borderStrong: Color { dynamicColor(NSColor.black.withAlphaComponent(0.15), NSColor.white.withAlphaComponent(0.14)) }

    static let text = dynamic(0x1d1d1f, 0xece9df)
    static let muted = dynamic(0x6e6e73, 0xa3aca6)
    static let muted2 = dynamic(0xaeaeb2, 0x7d8781)
    /// 电表绿：浅色用品牌原始 #447E72，深色提亮 #57a48f
    static let accent = dynamic(0x447e72, 0x57a48f)
    static let accentSoft = accent.opacity(0.14)
    static let ok = dynamic(0x34a853, 0x4cc38a)
    static let warn = dynamic(0xc98a1e, 0xe0a458)
    static let err = dynamic(0xd95a48, 0xe5735c)

    /// 主图系列配色（mainchart.ts PALETTE；浅色取加深变体保证白底可读）
    static let palette: [Color] = [
        dynamicColor(rgb(0x3f8a76), rgb(0x57a48f)),
        dynamicColor(rgb(0xb99f4e), rgb(0xd9c589)),
        dynamicColor(rgb(0xa8603f), rgb(0xc97b5d)),
        dynamicColor(rgb(0x5f7f92), rgb(0x7f98a8)),
        dynamicColor(rgb(0x6f8c52), rgb(0x8fa76f)),
        dynamicColor(rgb(0xb0783a), rgb(0xe0a458)),
        dynamicColor(rgb(0x4f8b83), rgb(0x6fa8a0)),
        dynamicColor(rgb(0x8f968a), rgb(0xb9c0ae)),
    ]

    /// 卡片环境阴影（浅色=柔和弥散、深色=更深沉）；替代生硬灰边框的层级表达
    static var cardShadow: Color {
        dynamicColor(NSColor.black.withAlphaComponent(0.07), NSColor.black.withAlphaComponent(0.35))
    }

    /// 辉光渐变透明度（浅色下减弱）
    static var glowOpacity: Double { bestMatchDark ? 0.10 : 0.05 }
    static var secondaryGlowOpacity: Double { bestMatchDark ? 0.04 : 0.03 }
    static var bestMatchDark: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension View {
    /// 统一卡片质感：连续圆角 + 主题面板底 + 柔和弥散阴影 + hairline 描边
    func wattsonCard(padding: CGFloat = 14, radius: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.panel)
                    .shadow(color: Theme.cardShadow, radius: 14, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.border)
            )
    }
}

extension Theme {
    /// AppKit 侧窗口背景（NSWindow.backgroundColor）
    static let nsBg: NSColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(0x14181a) : rgb(0xf5f5f7)
    }
}

extension View {
    /// 配额进度条：轨道浅面板 + 品牌渐变填充（hot 状态保持警示色）
    func quotaBar(fraction: Double, color: Color, height: CGFloat = 7) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.panel2)
                Capsule()
                    .fill(LinearGradient(colors: [color, color.opacity(0.78)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
    }
}

// MARK: - 格式化（web/src/format.ts 同口径）

enum Fmt {
    static func int(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.locale = Locale(identifier: "zh_CN")
        return f.string(from: NSNumber(value: n)) ?? String(Int64(n))
    }

    /// 1.23B / 4.56M / 78.9K
    static func tokens(_ n: Double) -> String {
        if n >= 1e9 { return String(format: "%.2fB", n / 1e9) }
        if n >= 1e6 { return String(format: "%.2fM", n / 1e6) }
        if n >= 1e3 { return String(format: "%.1fK", n / 1e3) }
        return String(Int64(n))
    }

    /// 未映射（nil）显示 —；小额保留 3 位精度
    static func cost(_ n: Double?) -> String {
        guard let n else { return "—" }
        return "$" + String(format: n < 10 ? "%.3f" : "%.2f", n)
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%.1f%%", v * 100)
    }

    static func time(_ ms: Double?) -> String {
        guard let ms else { return "—" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    static func clock(_ ms: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: ms / 1000))
    }

    /// 重置倒计时（看板 plan.ts 口径）：N天N时 / NhNm / Nm；已过 → 已可重置
    static func reset(_ ms: Double?) -> String {
        guard let ms else { return "" }
        let delta = ms - Date.nowMs()
        if delta <= 0 { return "已可重置" }
        let d = Int(delta / 86400_000)
        let h = Int(Int(delta.truncatingRemainder(dividingBy: 86400_000)) / 3600_000)
        let m = Int(round(delta.truncatingRemainder(dividingBy: 3600_000) / 60_000))
        if d > 0 { return "\(d)天\(h)时" }
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }

    /// 重置倒计时（popup 口径）：NdNh / NhNm / Nm；已过 → 已重置
    static func resetPopup(_ ms: Double?) -> String {
        guard let ms else { return "" }
        let delta = ms - Date.nowMs()
        if delta <= 0 { return "已重置" }
        let d = Int(delta / 86400_000)
        let h = Int(Int(delta.truncatingRemainder(dividingBy: 86400_000)) / 3600_000)
        let m = Int(round(delta.truncatingRemainder(dividingBy: 3600_000) / 60_000))
        if d > 0 { return "\(d)d\(h)h" }
        return h > 0 ? "\(h)h\(m)m" : "\(m)m"
    }
}

// MARK: - 短标签映射（web/src/plan.ts 同表）

enum QuotaShort {
    static let window: [String: String] = [
        "fiveHour": "5小时", "week": "周", "weekSonnet": "周·Sonnet", "extra": "额外",
        "cycle": "周期", "credits": "积分", "limit": "Key 限额",
        "editPredictions": "补全", "rate": "速率",
    ]
    static let kind: [String: String] = {
        var m: [String: String] = [:]
        for k in QuotaKind.allCases { m[k.rawValue] = k.rawValue.capitalizedFirstForQuota }
        m["glm"] = "GLM"; m["openrouter"] = "OpenRouter"; m["minimax"] = "MiniMax"
        m["workbuddy"] = "WorkBuddy"; m["codebuff"] = "Codebuff"; m["copilot"] = "Copilot"
        return m
    }()

    /// kind → 官方 logo 文件名（Bundle Resources/logos/；zed/codebuff/factory 走首字母兜底）
    static let logo: [String: String] = [
        "glm": "zai", "codex": "openai", "claude": "claude", "cursor": "cursor",
        "workbuddy": "codebuddy", "trae": "trae", "kimi": "kimi", "gemini": "gemini",
        "grok": "grok", "kiro": "kiro", "copilot": "github", "openrouter": "openrouter",
        "minimax": "minimax",
    ]
}

extension String {
    var capitalizedFirstForQuota: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Logo 渲染（SVG 资源 → NSImage；无 logo 走首字母圆底兜底）

struct BrandLogo: View {
    let kind: String
    var size: CGFloat = 28

    var body: some View {
        if let img = BrandLogo.image(for: kind) {
            Image(nsImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 0xf7/255, green: 0xf4/255, blue: 0xea/255),
                                                  Color(red: 0xe6/255, green: 0xe1/255, blue: 0xd5/255)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                Text(String((QuotaShort.kind[kind] ?? kind).prefix(1)).uppercased())
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(Color(red: 0x44/255, green: 0x70/255, blue: 0x62/255))
            }
            .frame(width: size, height: size)
        }
    }

    static func image(for kind: String) -> NSImage? {
        guard let name = QuotaShort.logo[kind] else { return nil }
        if let cached = cache[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "Resources/logos"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }

    private static var cache: [String: NSImage] = [:]
}
