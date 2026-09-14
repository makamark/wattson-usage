// HttpServerTests.swift — API 服务器：路由加固（Host/Origin）单测 + 端到端集成。
import XCTest
import Network
@testable import WattsonCore

final class HttpServerTests: XCTestCase {
    private func makeCollector() -> Collector {
        Collector(devices: [], localHost: "macair",
                  parseAll: {},
                  loadCache: {
                      SessionCache(providers: [
                          "zcode": ProviderSection(files: [
                              "/x/db.sqlite:s1": CachedFile(turns: [CachedTurn(timestamp: "2026-09-10T02:00:00.000Z", calls: [
                                  CachedCall(model: "glm-5.2",
                                             usage: CachedUsage(inputTokens: 10, outputTokens: 5),
                                             timestamp: "2026-09-10T02:00:00.000Z"),
                              ])]),
                          ]),
                      ])
                  })
    }

    private func makeServer(port: Int, refreshTrigger: @escaping () -> Void = {}) -> AggServer {
        AggServer(port: port, collector: makeCollector(),
                  instanceId: "id-test", configPath: "/x/agg.config.json",
                  refreshTrigger: refreshTrigger)
    }

    private func req(_ method: String, _ target: String, headers: [String: String]) -> HTTPRequest {
        HTTPRequest(method: method,
                    path: target.split(separator: "?").first.map(String.init) ?? target,
                    headers: headers,
                    query: ["range": "all"])
    }

    func testApiHostMustMatchBoundLoopbackExact() {
        let server = makeServer(port: 8317)
        // DNS-rebinding：Host 不精确等于 127.0.0.1:8317 一律 403（含形近端口）
        XCTAssertEqual(server.route(req("GET", "/api/status", headers: ["host": "evil.com"])).status, 403)
        XCTAssertEqual(server.route(req("GET", "/api/status", headers: ["host": "127.0.0.1:83170"])).status, 403)
        XCTAssertEqual(server.route(req("GET", "/api/status", headers: ["host": "localhost:8317"])).status, 403)
        XCTAssertEqual(server.route(req("GET", "/api/status", headers: ["host": "127.0.0.1:8317"])).status, 200)
    }

    func testRefreshPostRejectsCrossOriginAndAcceptsSameOrigin() {
        var triggered = false
        let server = makeServer(port: 8317) { triggered = true }
        let cross = server.route(req("POST", "/api/refresh", headers: [
            "host": "127.0.0.1:8317", "origin": "http://127.0.0.1:9999",
        ]))
        XCTAssertEqual(cross.status, 403)
        XCTAssertFalse(triggered)
        let same = server.route(req("POST", "/api/refresh", headers: [
            "host": "127.0.0.1:8317", "origin": "http://127.0.0.1:8317",
        ]))
        XCTAssertEqual(same.status, 202)
        XCTAssertTrue(triggered)
        let noOrigin = server.route(req("POST", "/api/refresh", headers: ["host": "127.0.0.1:8317"]))
        XCTAssertEqual(noOrigin.status, 202)
    }

    func testNonApiPathIs404() {
        let server = makeServer(port: 8317)
        XCTAssertEqual(server.route(req("GET", "/", headers: ["host": "127.0.0.1:8317"])).status, 404)
        XCTAssertEqual(server.route(req("GET", "/static/app.js", headers: ["host": "127.0.0.1:8317"])).status, 404)
    }

    func testStatusRouteIncludesHandshakeAndRecordCount() {
        let server = makeServer(port: 8317)
        let r = server.route(req("GET", "/api/status", headers: ["host": "127.0.0.1:8317"]))
        XCTAssertEqual(r.status, 200)
        let body = (try? JSON.parse(r.body)) ?? .null
        XCTAssertEqual(body["localHost"]?.str, "macair")
        XCTAssertEqual(body["instanceId"]?.str, "id-test")
        XCTAssertEqual(body["port"]?.num, 8317)
        XCTAssertEqual(body["recordCount"]?.num, 0)
    }

    /// 端到端：真实监听 127.0.0.1 随机端口，URLSession 打 /api/status 与 /api/refresh
    func testLiveServerServesApiOverLoopback() async throws {
        let port = try await freePort()
        let server = makeServer(port: port)
        try server.start()
        defer { server.stop() }
        let base = "http://127.0.0.1:\(port)"
        // 等端口就绪（冷启动：首采在后台，/api/status 不依赖它）
        var statusBody: JSON = .null
        for _ in 0..<50 {
            if let (data, resp) = try? await URLSession.shared.data(from: URL(string: "\(base)/api/status")!),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let j = try? JSON.parse(data) {
                statusBody = j
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(statusBody["localHost"]?.str, "macair")
        XCTAssertNotNil(statusBody["recordCount"]?.num)

        let request = makePostRequest(urlString: "\(base)/api/refresh")
        let (data, resp) = try await URLSession.shared.data(for: request)
        _ = data
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 202)
    }

    private func makePostRequest(urlString: String) -> URLRequest {
        var r = URLRequest(url: URL(string: urlString)!)
        r.httpMethod = "POST"
        return r
    }

    private func freePort() async throws -> Int {
        // BSD socket：bind 到 0 号端口拿内核分配的空闲端口
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw TestError("socket 创建失败") }
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw TestError("bind 失败") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        var out = sockaddr_in()
        let nameResult = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(sock, $0, &len)
            }
        }
        guard nameResult == 0 else { throw TestError("getsockname 失败") }
        return Int(UInt16(bigEndian: out.sin_port))
    }
}
