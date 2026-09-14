// Support/Fetch.swift — HTTP 抽象：测试注入 fake fetch，生产用 URLSession
// （Support/URLSessionFetch.swift）。TS FetchLike 的 Swift 对应物。
import Foundation

public struct FetchRequest: Sendable {
    public var url: String
    public var method: String
    public var headers: [String: String]
    public var body: String?

    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: String? = nil) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public struct FetchResponse: Sendable {
    public var status: Int
    public var body: JSON

    public init(status: Int, body: JSON) {
        self.status = status
        self.body = body
    }

    public var ok: Bool { status >= 200 && status < 300 }
}

public typealias FetchLike = @Sendable (FetchRequest) async throws -> FetchResponse

/// 带 HTTP 状态码的错误：provider 层据此区分 http_401 / http_error。
/// TS 侧用 Object.assign(new Error(...), { quotaHttpStatus }) 的惯用法，这里显式建模。
public struct HTTPStatusError: Error, Sendable, CustomStringConvertible {
    public let status: Int
    public let message: String

    public init(status: Int, message: String? = nil) {
        self.status = status
        self.message = message ?? "HTTP \(status)"
    }

    public var description: String { message }

    public static func unauthorized() -> HTTPStatusError {
        HTTPStatusError(status: 401, message: "HTTP 401（凭据无效或已过期）")
    }

    public static func forbidden() -> HTTPStatusError {
        HTTPStatusError(status: 403, message: "HTTP 403（凭据无效或已过期）")
    }
}

public func readHttpStatus(_ err: Error) -> Int? {
    guard let e = err as? HTTPStatusError else { return nil }
    // status 0 表示「非 HTTP 错误借用了该类型」（如业务码/无网络语义），不算 HTTP 状态
    return e.status == 0 ? nil : e.status
}

public func errText(_ err: Error) -> String {
    (err as? HTTPStatusError)?.message ?? err.localizedDescription
}

/// URLSession 实现（生产路径）。proxy 非空时把 HTTP/HTTPS 流量指向该代理——
/// 替代 TS 侧 undici ProxyAgent 的原生做法（chatgpt.com 等受限域名出网）。
public func makeHTTPFetch(proxy: String? = nil) -> FetchLike { { req in
    guard let url = URL(string: req.url) else {
        throw HTTPStatusError(status: 0, message: "无效 URL：\(req.url)")
    }
    var urlReq = URLRequest(url: url)
    urlReq.httpMethod = req.method
    urlReq.httpBody = req.body?.data(using: .utf8)
    for (k, v) in req.headers { urlReq.setValue(v, forHTTPHeaderField: k) }
    if let proxy {
        let parsed = parseProxyURL(proxy)
        urlReq.timeoutInterval = 20
        let conf = URLSessionConfiguration.ephemeral
        conf.connectionProxyDictionary = parsed
        let session = URLSession(configuration: conf)
        defer { session.finishTasksAndInvalidate() }
        let (data, resp) = try await session.data(for: urlReq)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSON.parse(data)) ?? .null
        return FetchResponse(status: status, body: body)
    }
    let (data, resp) = try await URLSession.shared.data(for: urlReq)
    let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let body = (try? JSON.parse(data)) ?? .null
    return FetchResponse(status: status, body: body)
} }

func parseProxyURL(_ raw: String) -> [AnyHashable: Any] {
    guard let url = URL(string: raw), let host = url.host else { return [:] }
    let port = url.port ?? 80
    return [
        kCFNetworkProxiesHTTPEnable as String: true,
        kCFNetworkProxiesHTTPProxy as String: host,
        kCFNetworkProxiesHTTPPort as String: port,
        "HTTPSEnable": true,
        "HTTPSProxy": host,
        "HTTPSPort": port,
    ]
}
