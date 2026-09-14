// TestSupport.swift — 测试公共设施：注入式 fake fetch、JWT 构造、临时目录。
import Foundation
import XCTest
@testable import WattsonCore

let DAY: Double = 24 * 3600 * 1000
let HOUR: Double = 3600 * 1000

/// 记录 fake fetch 收到的请求（零网络测试断言用）
final class FetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [FetchRequest] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var urls: [String] { all().map(\.url) }
    func last(offset: Int = 0) -> FetchRequest? {
        let idx = all().count - 1 - offset
        return idx >= 0 ? all()[idx] : nil
    }
    func all() -> [FetchRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    func append(_ r: FetchRequest) { lock.lock(); requests.append(r); lock.unlock() }
}

enum FakeRoute {
    case json(JSON)
    case error(Error)

    /// 取出 .json 路由的响应体（测试直接用 fixture 断言时）
    var wrapped: JSON {
        if case .json(let j) = self { return j }
        return .null
    }
}

/// TS fakeFetch 的对应物：按「URL 包含某 key」路由；未命中抛错。
func fakeFetch(_ routes: [String: FakeRoute], recorder: FetchRecorder = FetchRecorder()) -> FetchLike {
    return { req in
        recorder.append(req)
        guard let key = routes.keys.first(where: { req.url.contains($0) }) else {
            throw HTTPStatusError(status: 0, message: "unexpected url \(req.url)")
        }
        switch routes[key]! {
        case .json(let body):
            return FetchResponse(status: 200, body: body)
        case .error(let e):
            throw e
        }
    }
}

func jsonDict(_ any: Any) -> JSON {
    JSON.fromAny(any)
}

extension JSON {
    func encodedString() -> String {
        guard let data = try? encoded() else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// 形状合法的假 JWT（payload=payloadJson 的 base64url）
func fakeJwt(_ payload: [String: Any]) -> String {
    func b64(_ o: Any) -> String {
        let data = try! JSONSerialization.data(withJSONObject: o)
        return base64URLEncode(data)
    }
    return "\(b64(["alg": "RS256"])).\(b64(payload)).sig"
}

/// 带可控 gate 的 parseAll 桩（collector 并发语义测试用）
actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var resolved = false

    func wait() async {
        if resolved { return }
        await withCheckedContinuation { c in
            if resolved { c.resume() } else { continuation = c }
        }
    }

    func resolve() {
        resolved = true
        continuation?.resume()
        continuation = nil
    }
}

final class ParseBox: @unchecked Sendable {
    var parseCalls = 0
    var loadCacheCalls = 0
    var failParse = false
    var gate = Gate()
}

struct TestError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension XCTestCase {
    func makeTempDir(prefix: String) -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    func writeFixture(_ path: String, _ content: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// 轮询等待条件成立（并发测试：Swift Task 启动时序与 JS 同步语义不同）
    func waitUntil(timeout: Double = 5, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("waitUntil 超时") ; return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
