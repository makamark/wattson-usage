// Server/HttpServer.swift — 127.0.0.1 API 服务器（Network.framework 原生实现）。
// 路由语义与入口约定：
//   · /api/* 有 DNS-rebinding / 跨站加固：Host 必须精确等于 127.0.0.1:<port>；
//     POST /api/refresh 另拒跨源 Origin（表单 CSRF 一定带 Origin）
//   · POST /api/refresh 触发后台刷新，立即 202
//   · 其余 /api/* 走纯路由 handleApi
//   · 静态托管已由原生看板窗口取代：非 API 路径一律 404
import Foundation
import Network

public final class AggServer: @unchecked Sendable {
    public let port: Int
    public let collector: Collector
    public let quotaPoller: QuotaPoller?
    public let instanceId: String
    public let configPath: String
    private let refreshTrigger: () -> Void
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "wattson.http")
    private var connections: [NWConnection] = []

    public init(port: Int, collector: Collector, quotaPoller: QuotaPoller? = nil,
                instanceId: String = UUID().uuidString, configPath: String,
                refreshTrigger: @escaping () -> Void) {
        self.port = port
        self.collector = collector
        self.quotaPoller = quotaPoller
        self.instanceId = instanceId
        self.configPath = configPath
        self.refreshTrigger = refreshTrigger
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        guard let endpoint = NWEndpoint.Port(rawValue: UInt16(port)) else {
            throw HTTPStatusError(status: 0, message: "端口非法：\(port)")
        }
        let listener = try NWListener(using: params, on: endpoint)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.listener = nil }
        }
        listener.start(queue: queue)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        queue.async { [weak self] in
            self?.connections.forEach { $0.cancel() }
            self?.connections.removeAll()
        }
    }

    private func accept(_ conn: NWConnection) {
        queue.async { self.connections.append(conn) }
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let req = HTTPRequest.parse(buf) {
                let resp = self.route(req)
                conn.send(content: resp.data, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                return
            }
            if error != nil || done {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    func route(_ req: HTTPRequest) -> HTTPResponse {
        if req.path.hasPrefix("/api/") {
            // Host 必须精确等于绑定地址：防 DNS rebinding / 看似同源的端口前缀绕过
            if req.headers["host"] != "127.0.0.1:\(port)" {
                return HTTPResponse(status: 403, contentType: "application/json", body: Data())
            }
            if req.path == "/api/refresh" && req.method == "POST" {
                if let origin = req.headers["origin"],
                    !origin.hasPrefix("http://127.0.0.1:\(port)") {
                    return HTTPResponse(status: 403, contentType: "application/json", body: Data())
                }
                refreshTrigger()
                let body = try? JSON.obj(["ok": .bool(true)]).encoded()
                return HTTPResponse(status: 202, contentType: "application/json",
                                    body: body ?? Data("{}".utf8))
            }
            var target = req.path
            if !req.query.isEmpty {
                let qs = req.query.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                    .joined(separator: "&")
                target += "?" + qs
            }
            let result = handleApi(ApiRequest(target: target, method: req.method),
                                   collector.snapshot, collector.localHost,
                                   handshake: [
                                        "instanceId": .str(instanceId),
                                        "configPath": .str(configPath),
                                        "port": .num(Double(port)),
                                   ],
                                   plan: quotaPoller?.snapshotValue)
            let body = (try? result.body.encoded()) ?? Data("{}".utf8)
            return HTTPResponse(status: result.status, contentType: "application/json", body: body)
        }
        return HTTPResponse(status: 404, contentType: "text/plain; charset=utf-8", body: Data("not found".utf8))
    }
}

struct HTTPRequest {
    var method: String
    var path: String
    var headers: [String: String]
    var query: [String: String]

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[data.startIndex..<headEnd.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let idx = line.firstIndex(of: ":") else { continue }
            let k = String(line[..<idx]).trimmingCharacters(in: .whitespaces).lowercased()
            let v = String(line[line.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        let target = parts[1]
        let split = target.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if split.count > 1 {
            for pair in split[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1).map { $0.removingPercentEncoding ?? String($0) }
                if let k = kv.first { query[k] = kv.count > 1 ? kv[1] : "" }
            }
        }
        return HTTPRequest(method: parts[0].uppercased(), path: split[0], headers: headers, query: query)
    }
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    var data: Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        default: reason = "Error"
        }
        var head = "HTTP/1.1 \(status) \(reason)\r\ncontent-type: \(contentType)\r\ncontent-length: \(body.count)\r\nconnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}
