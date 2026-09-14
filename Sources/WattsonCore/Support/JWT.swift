// Support/JWT.swift — 只解码 JWT payload（不验签）：codex/cursor 从中取账户 id。
import Foundation

public func base64URLDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
        .replacingOccurrences(of: "=", with: "")
    let pad = (4 - t.count % 4) % 4
    t += String(repeating: "=", count: pad)
    return Data(base64Encoded: t)
}

public func base64URLEncode(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// 形如 a.b.c 的 JWT payload 解码；非 JWT 返回 nil
public func jwtPayload(_ token: String) -> JSON? {
    let parts = token.split(separator: ".").map(String.init)
    guard parts.count == 3, let data = base64URLDecode(parts[1]),
          let json = try? JSON.parse(data) else { return nil }
    return json
}
