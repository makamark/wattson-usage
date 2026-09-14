// Support/JSON.swift — 动态 JSON 值模型。
// 各上游接口响应结构演进频繁（字段增删、字符串数字、null 兜底），provider 层
// 需要与 TS `unknown` 同款的动态探测语义；这里给一个轻量不可变 JSON 树，
// 解析/序列化走 JSONSerialization，访问走 Optional 下标，绝不因形状不符而崩溃。
import Foundation

public enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case num(Double)
    case str(String)
    case arr([JSON])
    case obj([String: JSON])

    // MARK: 解析 / 序列化

    public static func parse(_ data: Data) throws -> JSON {
        let raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return JSON.fromAny(raw)
    }

    public static func parse(_ string: String) throws -> JSON {
        guard let data = string.data(using: .utf8) else { throw JSONError.encoding }
        return try parse(data)
    }

    public enum JSONError: Error { case encoding, invalid }

    public static func fromAny(_ v: Any) -> JSON {
        switch v {
        case is NSNull:
            return .null
        case let j as JSON:
            return j
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .num(n.doubleValue)
        case let s as String:
            return .str(s)
        case let a as [Any]:
            return .arr(a.map(JSON.fromAny))
        case let d as [String: Any]:
            return .obj(d.mapValues(JSON.fromAny))
        default:
            return .null
        }
    }

    public func encoded(pretty: Bool = false) throws -> Data {
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .fragmentsAllowed]
        if pretty { options.insert(.prettyPrinted) }
        return try JSONSerialization.data(withJSONObject: nsAny, options: options)
    }

    public var nsAny: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b as NSNumber
        case .num(let n):
            // 整数不带小数点序列化（与 JS JSON.stringify 口径一致）
            if n.truncatingRemainder(dividingBy: 1) == 0, abs(n) < 9.007_199_254_740_992e15 {
                return Int64(n) as NSNumber
            }
            return n as NSNumber
        case .str(let s): return s
        case .arr(let a): return a.map(\.nsAny)
        case .obj(let o): return o.mapValues(\.nsAny)
        }
    }

    // MARK: 取值

    public var isNull: Bool { if case .null = self { return true }; return false }
    /// TS `typeof v === 'number'` 口径：布尔不是数字
    public var num: Double? {
        if case .num(let n) = self, n.isFinite { return n }
        return nil
    }
    public var str: String? {
        if case .str(let s) = self { return s }
        return nil
    }
    public var bool: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    public var arr: [JSON]? {
        if case .arr(let a) = self { return a }
        return nil
    }
    public var obj: [String: JSON]? {
        if case .obj(let o) = self { return o }
        return nil
    }

    public subscript(key: String) -> JSON? { obj?[key] }
    public subscript(index: Int) -> JSON? { arr?[index] }
}
