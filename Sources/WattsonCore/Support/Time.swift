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

    // 快路径：ISO-8601（本管线所有解析器产出的时间戳形状）。
    // DateFormatter/ISO8601DateFormatter 即使缓存实例也要 ~58µs/次（ICU 解析），
    // 4 万行就是 2.3s；手写解析约 1µs，把刷新链路的瓶颈从时间解析上移开。
    if let fast = parseISO8601Fast(trimmed) { return fast }

    // 纯日期（无 T 无时区）→ UTC 零点
    if trimmed.count == 10, trimmed.contains("T") == false, trimmed.contains("Z") == false,
       let d = formatter("yyyy-MM-dd", timeZone: TimeZone(secondsFromGMT: 0)!).date(from: trimmed) {
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
        if let d = formatter(fmt, timeZone: TimeZone.current).date(from: normalized) {
            return d.timeIntervalSince1970 * 1000
        }
    }
    return nil
}

/// 手写 ISO-8601 解析：`YYYY-MM-DDTHH:MM[:SS[.fff...]][Z|±HH:MM]`。
/// 只接管「带显式时区」的形状（本管线全部真实数据都如此），其余仍交给 DateFormatter。
/// 直接按 UTC 偏移算 epoch，不让任何时区数据库/ICU 参与。
func parseISO8601Fast(_ s: String) -> Double? {
    let b = Array(s.utf8)
    guard b.count >= 17 else { return nil }
    // 结构校验：日期段与时间段的固定分隔符位置
    guard b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A else { return nil }
    guard let year = dec4(b, 0), let month = dec2(b, 5), let day = dec2(b, 8),
          let hour = dec2(b, 11), let minute = dec2(b, 14) else { return nil }
    var idx = 16
    var second = 0
    var millis = 0.0
    if idx < b.count, b[idx] == 0x3A {         // ':' → 带秒
        guard let sec = dec2(b, idx + 1) else { return nil }
        second = sec
        idx += 3
        if idx < b.count, b[idx] == 0x2E {     // '.' → 小数秒，按毫秒精度取前 3 位
            idx += 1
            var scale = 100.0
            while idx < b.count, b[idx] >= 0x30, b[idx] <= 0x39 {
                if scale >= 1 { millis += Double(b[idx] - 0x30) * scale; scale /= 10 }
                idx += 1
            }
        }
    }
    // 时区：Z 或 ±HH:MM；两者都不是 → 不属于快路径形状
    var offsetSeconds = 0
    if idx < b.count, b[idx] == 0x5A {         // 'Z'
        idx += 1
    } else if idx < b.count, b[idx] == 0x2B || b[idx] == 0x2D {
        let sign = b[idx] == 0x2D ? -1 : 1
        idx += 1
        guard let oh = dec2(b, idx) else { return nil }
        idx += 2
        if idx < b.count, b[idx] == 0x3A { idx += 1 }
        guard let om = dec2(b, idx) else { return nil }
        idx += 2
        offsetSeconds = sign * (oh * 3600 + om * 60)
    } else {
        return nil
    }
    guard idx == b.count else { return nil }   // 尾部有多余字符 → 交给兜底
    guard month >= 1, month <= 12, day >= 1, day <= 31,
          hour <= 23, minute <= 59, second <= 60 else { return nil }

    // 民用日期 → 距 1970-01-01 的天数（Howard Hinnant days_from_civil）
    var y = year
    y -= month <= 2 ? 1 : 0
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    let days = era * 146097 + doe - 719468

    let seconds = Double(days) * 86400 + Double(hour) * 3600 + Double(minute) * 60
        + Double(second) - Double(offsetSeconds)
    return seconds * 1000 + millis
}

/// 固定宽度十进制数字；不足位或非数字返回 nil
private func dec2(_ b: [UInt8], _ i: Int) -> Int? {
    guard i + 1 < b.count else { return nil }
    let a = Int(b[i]) - 0x30, c = Int(b[i + 1]) - 0x30
    guard a >= 0, a <= 9, c >= 0, c <= 9 else { return nil }
    return a * 10 + c
}

private func dec4(_ b: [UInt8], _ i: Int) -> Int? {
    guard i + 3 < b.count else { return nil }
    var v = 0
    for k in i..<(i + 4) {
        let d = Int(b[k]) - 0x30
        guard d >= 0, d <= 9 else { return nil }
        v = v * 10 + d
    }
    return v
}

// MARK: - 格式化器缓存
// 每行用量都要解析一次时间戳：每秒新建 ISO8601DateFormatter/DateFormatter 会让
// rowsFromCache 变成整个刷新链路的瓶颈（本机 4 万行实测 6.4s，缓存后 <0.1s）。
// DateFormatter/ISO8601DateFormatter 的解析是线程安全的，可跨线程复用。
private let formatterLock = NSLock()
private var formatterCache: [String: DateFormatter] = [:]
private var isoCache: [Bool: ISO8601DateFormatter] = [:]

private func formatter(_ fmt: String, timeZone: TimeZone) -> DateFormatter {
    let key = "\(fmt)|\(timeZone.identifier)"
    formatterLock.lock(); defer { formatterLock.unlock() }
    if let cached = formatterCache[key] { return cached }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = fmt
    f.timeZone = timeZone
    formatterCache[key] = f
    return f
}

private func isoFormatter(fractional: Bool) -> ISO8601DateFormatter {
    formatterLock.lock(); defer { formatterLock.unlock() }
    if let cached = isoCache[fractional] { return cached }
    let f = ISO8601DateFormatter()
    if fractional { f.formatOptions = [.withInternetDateTime, .withFractionalSeconds] }
    isoCache[fractional] = f
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
