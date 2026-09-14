// Quotas/Proxy.swift — 额度接口出网代理解析：显式 HTTP(S)_PROXY env 优先；
// 否则 macOS 用 `scutil --proxy` 探测系统代理（chatgpt.com 等受限域名出网）。
import Foundation

public struct SystemProxy: Sendable, Equatable {
    public var httpsProxy: String?
    public var httpProxy: String?
}

/// 解析 `scutil --proxy` 输出（macOS）；解析失败返回空
public func parseScutilProxy(_ output: String) -> SystemProxy {
    func get(_ key: String) -> String? {
        let pattern = "^\\s*\(key)\\s*:\\s*(\\S+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]),
              let m = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let r = Range(m.range(at: 1), in: output) else { return nil }
        return String(output[r])
    }
    func enabled(_ key: String) -> Bool { get(key) == "1" }
    func host(_ key: String) -> String? {
        guard let v = get(key), v != "0.0.0.0" else { return nil }
        return v
    }
    func port(_ key: String) -> String? {
        guard let v = get(key), v != "0" else { return nil }
        return v
    }
    func build(_ enableKey: String, _ hostKey: String, _ portKey: String) -> String? {
        guard enabled(enableKey) else { return nil }
        let h = host(hostKey)
        let p = port(portKey)
        if let h, let p { return "http://\(h):\(p)" }
        return h.map { "http://\($0)" }
    }
    return SystemProxy(
        httpsProxy: build("HTTPSEnable", "HTTPSProxy", "HTTPSPort"),
        httpProxy: build("HTTPEnable", "HTTPProxy", "HTTPPort"))
}

/// 运行系统 scutil（生产路径）
public func runScutilProxy() -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
    p.arguments = ["--proxy"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do {
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    } catch {
        return ""
    }
}

/// 代理地址解析：显式 env 优先，其次 macOS 系统代理；都没有返回 nil（直连）
public func resolveProxyUrl(env: [String: String] = [:], platform: String = "darwin",
                            scutil: (() -> String)? = nil) -> String? {
    let explicit = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? env["HTTP_PROXY"] ?? env["http_proxy"]
    if let explicit, !explicit.trimmingCharacters(in: .whitespaces).isEmpty {
        return explicit.trimmingCharacters(in: .whitespaces)
    }
    guard platform == "darwin" else { return nil }
    let out = scutil?() ?? runScutilProxy()
    let sys = parseScutilProxy(out)
    return sys.httpsProxy ?? sys.httpProxy
}

/// 构造额度接口专用 fetch：配置了代理时走系统代理（URLSession connectionProxyDictionary），
/// 否则直连。Swift 原生实现无进程启动时机限制，运行时生效。
public func createQuotaFetch(env: [String: String] = [:], platform: String = "darwin",
                             scutil: (() -> String)? = nil) -> (fetchLike: FetchLike, proxyUrl: String?) {
    let proxyUrl = resolveProxyUrl(env: env, platform: platform, scutil: scutil)
    return (makeHTTPFetch(proxy: proxyUrl), proxyUrl)
}
