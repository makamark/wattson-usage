// Theme.swift — 炭黑仪表风主题（与原 web/src/style.css / popup 同源设计语言）
// 与格式化工具（与 web/src/format.ts 同口径）。
import SwiftUI
import WattsonCore

enum Theme {
    static let bg = Color(red: 0x14/255, green: 0x18/255, blue: 0x1a/255)
    static let bgSoft = Color(red: 0x19/255, green: 0x1e/255, blue: 0x20/255)
    static let panel = Color(red: 0x22/255, green: 0x28/255, blue: 0x2a/255)
    static let panel2 = Color(red: 0x2a/255, green: 0x31/255, blue: 0x34/255)
    static let panel3 = Color(red: 0x33/255, green: 0x3b/255, blue: 0x3e/255)
    static let border = Color.white.opacity(0.07)
    static let borderStrong = Color.white.opacity(0.14)
    static let text = Color(red: 0xec/255, green: 0xe9/255, blue: 0xdf/255)
    static let muted = Color(red: 0xa3/255, green: 0xac/255, blue: 0xa6/255)
    static let muted2 = Color(red: 0x7d/255, green: 0x87/255, blue: 0x81/255)
    /// 电表绿（暗底提亮）
    static let accent = Color(red: 0x57/255, green: 0xa4/255, blue: 0x8f/255)
    static let accentSoft = Color.accentColor.opacity(0.16)
    static let ok = Color(red: 0x4c/255, green: 0xc3/255, blue: 0x8a/255)
    static let warn = Color(red: 0xe0/255, green: 0xa4/255, blue: 0x58/255)
    static let err = Color(red: 0xe5/255, green: 0x73/255, blue: 0x5c/255)

    /// 主图系列配色（mainchart.ts PALETTE）
    static let palette: [Color] = [
        Color(red: 0x57/255, green: 0xa4/255, blue: 0x8f/255),
        Color(red: 0xd9/255, green: 0xc5/255, blue: 0x89/255),
        Color(red: 0xc9/255, green: 0x7b/255, blue: 0x5d/255),
        Color(red: 0x7f/255, green: 0x98/255, blue: 0xa8/255),
        Color(red: 0x8f/255, green: 0xa7/255, blue: 0x6f/255),
        Color(red: 0xe0/255, green: 0xa4/255, blue: 0x58/255),
        Color(red: 0x6f/255, green: 0xa8/255, blue: 0xa0/255),
        Color(red: 0xb9/255, green: 0xc0/255, blue: 0xae/255),
    ]
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
