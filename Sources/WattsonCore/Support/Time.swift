// Support/Time.swift — 时间工具：epoch 毫秒归一（兼容秒/毫秒/ISO/带空格格式）
// 与本地时区的时间桶起点。TS Date.parse 语义的 Swift 对应物：
//   · "2026-10-01"（纯日期）→ UTC 零点
//   · "2026-10-01T00:00:00" / "2026-10-01 00:00:00"（无时区）→ 本地时间
//   · 带 Z / ±offset → 按所带时区
import Foundation

public enum TimeError: Error { case unparseable }

extension Date {
    public static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

/// JS Date.parse 的常用子集；解析失败返回 nil（与 Number.isFinite(NaN)===false 一致）
public func parseJSDate(_ s: String) -> Double? {
    let trimmed = s.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }

    // 纯日期（无 T 无时区）→ UTC 零点
    if trimmed.count == 10, trimmed.contains("T") == false, trimmed.contains("Z") == false,
       let d = dateFormatter("yyyy-MM-dd", timeZone: TimeZone(secondsFromGMT: 0)!)
        .date(from: trimmed) {
        return d.timeIntervalSince1970 * 1000
    }

    let normalized = trimmed.replacingOccurrences(of: " ", with: "T")

    // 带 Z / ±hh:mm 偏移 → ISO8601
    if let iso = isoFormatter(fractional: false).date(from: normalized)
        ?? isoFormatter(fractional: true).date(from: normalized) {
        return iso.timeIntervalSince1970 * 1000
    }

    // 无时区 → 本地时间
    for fmt in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm"] {
        if let d = dateFormatter(fmt, timeZone: TimeZone.current).date(from: normalized) {
            return d.timeIntervalSince1970 * 1000
        }
    }
    return nil
}

private func dateFormatter(_ fmt: String, timeZone: TimeZone) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = fmt
    f.timeZone = timeZone
    return f
}

private func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
    let f = ISO8601DateFormatter()
    if fractional { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    return f
}

/// 把 epoch 秒/毫秒或 ISO 字符串归一成 ms；无效为 nil（quotas/types.ts toEpochMs）
public func toEpochMs(_ v: JSON?) -> Double? {
    if let n = v?.num {
        if n <= 0 { return nil }
        return n < 1e12 ? n * 1000 : n
    }
    if let s = v?.str, !s.trimmingCharacters(in: .whitespaces).isEmpty {
        let t = parseJSDate(s)
        if let t { return t }
    }
    return nil
}

/// 本地时区的桶起点（aggregate.ts bucketStart）：
/// hour → 截到整点；day → 本地零点（跨 DST 由 Calendar 语义保证落点正确）
public func bucketStart(_ tsMs: Double, _ bucket: String) -> Double {
    let date = Date(timeIntervalSince1970: tsMs / 1000)
    let cal = Calendar.current
    if bucket == "hour" {
        let comps = cal.dateComponents([.year, .month, .day, .hour], from: date)
        return cal.date(from: comps).map { $0.timeIntervalSince1970 * 1000 } ?? tsMs
    }
    return cal.startOfDay(for: date).timeIntervalSince1970 * 1000
}

/// 本地零点（api.ts range=today 用）
public func localMidnight(_ nowMs: Double) -> Double {
    bucketStart(nowMs, "day")
}

/// overview 的 activeDays 口径：本地日历日键
public func dayKey(_ tsMs: Double) -> String {
    let comps = Calendar.current.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: tsMs / 1000))
    return "\(comps.year ?? 0)-\(comps.month ?? 0)-\(comps.day ?? 0)"
}
