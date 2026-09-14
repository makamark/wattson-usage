// Parsing/SessionScanner.swift — 原生会话扫描管线。
// 直接发现并解析本机/镜像的 AI 工具会话数据源，产出 SessionCache（聚合层输入）：
//   · claude     ~/.claude/projects/<slug>/*.jsonl（assistant 条目的 message.usage）
//   · codex      ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl + archived_sessions/
//                （token_count 事件里的 total_token_usage 累计值；取每文件终值防重复计费）
//   · zcode      ~/.zcode/cli/db/db.sqlite（镜像投影同构：session/model_usage/tool_usage）
//                经系统 sqlite3 -json 只读查询
//   · workbuddy  ~/.workbuddy/workbuddy.db（session_usage 会话级估算）
// 源缺失/不可读按「该源不存在」跳过；单源损坏不阻塞其它源。
import Foundation

/// 全量扫描全部数据源（原生管线无增量缓存，扫描本身轻量）
public func parseAllSessions(home: String = homePath(),
                             devices: [DeviceRoot] = loadDeviceRoots(),
                             run: RunLike = runProcess) async throws {
    let cache = await scanAllSources(home: home, devices: devices, run: run)
    SessionStore.shared.set(cache)
}

/// 读取最近一次扫描的缓存（供 Collector 与 rowsFromCache 消费）
public func loadSessionCache() throws -> SessionCache {
    guard let cache = SessionStore.shared.get() else {
        throw HTTPStatusError(status: 0, message: "会话缓存尚未初始化")
    }
    return cache
}

/// 进程内的会话缓存仓库：parseAllSessions 写入，loadSessionCache 读取。
/// 相当于 TS 侧的磁盘增量缓存——原生实现改为进程内存放（解析本身轻量）。
public final class SessionStore: @unchecked Sendable {
    public static let shared = SessionStore()
    private let lock = NSLock()
    private var cache: SessionCache?
    func set(_ c: SessionCache) { lock.lock(); cache = c; lock.unlock() }
    func get() -> SessionCache? { lock.lock(); defer { lock.unlock() }; return cache }
}

func sqliteJSONRows(_ run: RunLike, _ dbPath: String, _ sql: String) async -> [JSON] {
    guard let (stdout, _) = try? await run("sqlite3", ["-json", dbPath, sql]) else { return [] }
    guard let parsed = try? JSON.parse(stdout), let rows = parsed.arr else { return [] }
    return rows
}

public func scanAllSources(home: String = homePath(),
                           devices: [DeviceRoot] = loadDeviceRoots(),
                           run: RunLike = runProcess) async -> SessionCache {
    var providers: [String: ProviderSection] = [:]
    var files: [String: CachedFile] = [:]

    // ---------- claude ----------
    let claudeRoots: [String] = [(home as NSString).appendingPathComponent(".claude/projects")]
    for root in claudeRoots {
        for (path, calls) in parseClaudeProject(root) {
            files[path] = calls
        }
    }
    if !files.isEmpty { providers["claude"] = ProviderSection(envFingerprint: "native", files: files) }

    // ---------- codex ----------
    var codexFiles: [String: CachedFile] = [:]
    var codexRoots: [String] = [(home as NSString).appendingPathComponent(".codex")]
    codexRoots.append(contentsOf: devices.compactMap(\.codexHome))
    for root in codexRoots {
        for (path, file) in parseCodexSessions(root) {
            codexFiles[path] = file
        }
    }
    if !codexFiles.isEmpty { providers["codex"] = ProviderSection(envFingerprint: "native", files: codexFiles) }

    // ---------- zcode ----------
    var zcodeFiles: [String: CachedFile] = [:]
    var zcodeDbs: [String] = [(home as NSString).appendingPathComponent(".zcode/cli/db/db.sqlite")]
    zcodeDbs.append(contentsOf: devices.compactMap(\.zcodeDb))
    for db in zcodeDbs {
        guard fileExists(db) else { continue }
        if let file = await parseZcodeDatabase(db, run: run) {
            zcodeFiles["\(db):sessions"] = file
        }
    }
    if !zcodeFiles.isEmpty { providers["zcode"] = ProviderSection(envFingerprint: "native", files: zcodeFiles) }

    // ---------- workbuddy ----------
    var wbFiles: [String: CachedFile] = [:]
    var wbDbs: [String] = [(home as NSString).appendingPathComponent(".workbuddy/workbuddy.db")]
    wbDbs.append(contentsOf: devices.compactMap(\.workbuddyDb))
    for db in wbDbs {
        guard fileExists(db) else { continue }
        if let file = await parseWorkbuddyDatabase(db, run: run) {
            wbFiles["\(db):sessions"] = file
        }
    }
    if !wbFiles.isEmpty { providers["workbuddy"] = ProviderSection(envFingerprint: "native", files: wbFiles) }

    return SessionCache(version: 9, complete: true, providers: providers)
}

// MARK: - claude（JSONL：assistant 条目 message.usage）

func parseClaudeProject(_ projectsDir: String) -> [(path: String, file: CachedFile)] {
    var out: [(String, CachedFile)] = []
    for slug in listDirectory(projectsDir) {
        let dir = (projectsDir as NSString).appendingPathComponent(slug)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        for name in listDirectory(dir) where name.hasSuffix(".jsonl") {
            let path = (dir as NSString).appendingPathComponent(name)
            guard let raw = readDataFile(path) else { continue }
            var calls: [CachedCall] = []
            let mAssistant = Data("\"assistant\"".utf8)
            let mUsage = Data("\"usage\"".utf8)
            forEachLine(raw) { line in
                // 预过滤：只解析同时含 assistant 与 usage 标记的行（绝大多数行直接跳过）
                guard line.range(of: mAssistant) != nil, line.range(of: mUsage) != nil else { return }
                guard let entry = try? JSON.parse(line) else { return }
                guard entry["type"]?.str == "assistant" || entry["type"] == nil else { return }
                guard let usageNode = entry["message"]?["usage"], usageNode.obj != nil else { return }
                let ts = entry["timestamp"]?.str ?? ""
                // project 优先取条目 cwd，回退目录 slug
                let project = entry["cwd"]?.str ?? slug
                calls.append(CachedCall(
                    model: entry["message"]?["model"]?.str,
                    usage: CachedUsage(
                        inputTokens: aggNum(usageNode["input_tokens"]),
                        outputTokens: aggNum(usageNode["output_tokens"]),
                        cacheCreationInputTokens: aggNum(usageNode["cache_creation_input_tokens"]),
                        cacheReadInputTokens: aggNum(usageNode["cache_read_input_tokens"]),
                        reasoningTokens: aggNum(usageNode["reasoning_tokens"])),
                    timestamp: ts,
                    project: project))
            }
            if !calls.isEmpty {
                out.append((path, CachedFile(fingerprint: fingerprintFor(path), turns: [
                    CachedTurn(timestamp: calls[0].timestamp, calls: calls),
                ])))
            }
        }
    }
    return out
}

func fingerprintFor(_ path: String) -> FileFingerprint? {
    let attrs = try? FileManager.default.attributesOfItem(atPath: path)
    guard let attrs else { return nil }
    let size = (attrs[.size] as? NSNumber)?.doubleValue ?? 0
    let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let ino = (attrs[.systemFileNumber] as? NSNumber)?.doubleValue ?? 0
    let dev = (attrs[.deviceIdentifier] as? NSNumber)?.doubleValue ?? 0
    return FileFingerprint(dev: dev, ino: ino, mtimeMs: mtime * 1000, sizeBytes: size)
}

// MARK: - codex（JSONL：token_count 事件的 total_token_usage 累计值）

func parseCodexSessions(_ codexHome: String) -> [(path: String, file: CachedFile)] {
    var out: [String: CachedFile] = [:]
    let sessionsDir = (codexHome as NSString).appendingPathComponent("sessions")
    let archivedDir = (codexHome as NSString).appendingPathComponent("archived_sessions")
    var rolloutPaths: [String] = []
    // sessions/YYYY/MM/DD/rollout-*.jsonl
    for year in listDirectory(sessionsDir) where year.count == 4 && year.allSatisfy(\.isNumber) {
        let yd = (sessionsDir as NSString).appendingPathComponent(year)
        for month in listDirectory(yd) {
            let md = (yd as NSString).appendingPathComponent(month)
            for day in listDirectory(md) {
                let dd = (md as NSString).appendingPathComponent(day)
                for name in listDirectory(dd) where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                    rolloutPaths.append((dd as NSString).appendingPathComponent(name))
                }
            }
        }
    }
    for name in listDirectory(archivedDir) where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
        rolloutPaths.append((archivedDir as NSString).appendingPathComponent(name))
    }
    for path in rolloutPaths {
        if let file = parseCodexRollout(path) { out[path] = file }
    }
    return out.map { ($0.key, $0.value) }
}

func parseCodexRollout(_ path: String) -> CachedFile? {
    guard let raw = readDataFile(path) else { return nil }
    var lastUsage: CachedUsage?
    var lastTs = ""
    var model: String?
    var project: String?
    var sessionId: String?
    let mTokenCount = Data("\"token_count\"".utf8)
    let mSessionMeta = Data("\"session_meta\"".utf8)
    // 预过滤：只解析 token_count（用量）与 session_meta（元数据）行，跳过其余绝大多数事件
    forEachLine(raw) { line in
        let isTokenCount = line.range(of: mTokenCount) != nil
        let isSessionMeta = line.range(of: mSessionMeta) != nil
        guard isTokenCount || isSessionMeta else { return }
        guard let entry = try? JSON.parse(line) else { return }
        if let sid = entry["session_id"]?.str { sessionId = sid }
        if let cwd = entry["payload"]?["cwd"]?.str ?? entry["cwd"]?.str { project = cwd }
        if let m = entry["payload"]?["model"]?.str ?? entry["payload"]?["model_id"]?.str
            ?? entry["payload"]?["info"]?["model_id"]?.str { model = m }
        guard isTokenCount else { return }
        // 形状一：token_count 事件 payload.info.total_token_usage（累计值）
        var total: JSON? = entry["payload"]?["info"]?["total_token_usage"]
        // 形状二：直接挂 total_token_usage 的历史格式
        if total == nil { total = entry["payload"]?["total_token_usage"] ?? entry["total_token_usage"] }
        guard let t = total, t.obj != nil else { return }
        let input = aggNum(t["input_tokens"])
        let cached = aggNum(t["cached_input_tokens"])
        let output = aggNum(t["output_tokens"])
        let reasoning = aggNum(t["reasoning_output_tokens"])
        // codex 的 input_tokens 已含 cached（OpenAI 口径）：拆出 fresh input
        lastUsage = CachedUsage(
            inputTokens: max(0, input - cached),
            outputTokens: output,
            cacheReadInputTokens: cached,
            reasoningTokens: reasoning)
        lastTs = entry["timestamp"]?.str ?? lastTs
    }
    guard let usage = lastUsage, (usage.inputTokens + usage.outputTokens) > 0 else { return nil }
    return CachedFile(fingerprint: fingerprintFor(path), turns: [
        CachedTurn(timestamp: lastTs, sessionId: sessionId, calls: [
            CachedCall(model: model ?? "unknown", usage: usage,
                       timestamp: lastTs, project: project),
        ]),
    ])
}

// MARK: - zcode（SQLite：session / model_usage 投影）

func parseZcodeDatabase(_ dbPath: String, run: RunLike) async -> CachedFile? {
    // 只取任一 token 维度非零的行（与解析口径一致），避免大库全量 JSON dump
    let usageRows = await sqliteJSONRows(run, dbPath, """
        SELECT session_id, turn_id, model_id, input_tokens, output_tokens, reasoning_tokens,
               cache_creation_input_tokens, cache_read_input_tokens, started_at, completed_at
        FROM model_usage
        WHERE input_tokens > 0 OR output_tokens > 0 OR reasoning_tokens > 0
           OR cache_read_input_tokens > 0 OR cache_creation_input_tokens > 0
        ORDER BY rowid
        """)
    guard !usageRows.isEmpty else { return nil }
    let sessionRows = await sqliteJSONRows(run, dbPath, "SELECT id, directory FROM session")
    let dirById = Dictionary(sessionRows.compactMap { row in
        row["id"]?.str.map { ($0, row["directory"]?.str ?? "unknown") }
    }, uniquingKeysWith: { a, _ in a })

    // 按 session 聚合（键 = <db>:<sessionId>，与 hostForSourcePath 的冒号前缀匹配约定一致）
    var bySession: [String: [CachedCall]] = [:]
    for row in usageRows {
        guard let sessionId = row["session_id"]?.str else { continue }
        let input = aggNum(row["input_tokens"])
        let output = aggNum(row["output_tokens"])
        let reasoning = aggNum(row["reasoning_tokens"])
        let cacheCreation = aggNum(row["cache_creation_input_tokens"])
        let cacheRead = aggNum(row["cache_read_input_tokens"])
        // ZCode 把缓存 token 折进 input_tokens（OpenAI 口径）：拆回 fresh input，
        // 让新鲜输入按输入价、缓存读取按读取价计
        let freshInput = max(0, input - cacheRead - cacheCreation)
        if freshInput == 0 && output == 0 && reasoning == 0 && cacheRead == 0 && cacheCreation == 0 { continue }
        let model = row["model_id"]?.str ?? "unknown"
        let cost = calculateCost(model: model, inputTokens: freshInput, outputTokens: output,
                                 cacheCreationTokens: cacheCreation, cacheReadTokens: cacheRead)
        let tsMs = toEpochMs(row["completed_at"]) ?? toEpochMs(row["started_at"])
        let tsISO = tsMs.map { ISO8601Format(ms: $0) } ?? ""
        bySession[sessionId, default: []].append(CachedCall(
            model: model,
            usage: CachedUsage(
                inputTokens: freshInput, outputTokens: output,
                cacheCreationInputTokens: cacheCreation, cacheReadInputTokens: cacheRead,
                reasoningTokens: reasoning),
            costUSD: cost,
            timestamp: tsISO,
            project: dirById[sessionId]))
    }
    var turns: [CachedTurn] = []
    for (sessionId, calls) in bySession {
        turns.append(CachedTurn(timestamp: calls.first?.timestamp ?? "", sessionId: sessionId, calls: calls))
    }
    return CachedFile(fingerprint: fingerprintFor(dbPath), turns: turns)
}

func ISO8601Format(ms: Double) -> String {
    let d = Date(timeIntervalSince1970: ms / 1000)
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.string(from: d)
}

// MARK: - workbuddy（SQLite：session_usage 会话级估算）

func parseWorkbuddyDatabase(_ dbPath: String, run: RunLike) async -> CachedFile? {
    let rows = await sqliteJSONRows(run, dbPath, """
        SELECT su.session_id as session_id, su.used as used, su.updated_at as updated_at
        FROM session_usage su JOIN sessions s ON s.id = su.session_id
        """)
    guard !rows.isEmpty else { return nil }
    var calls: [CachedCall] = []
    for row in rows {
        guard let used = row["used"]?.num, used > 0 else { continue }
        calls.append(CachedCall(
            model: "unknown",
            usage: CachedUsage(outputTokens: used),
            timestamp: toEpochMs(row["updated_at"]).map { ISO8601Format(ms: $0) } ?? ""))
    }
    guard !calls.isEmpty else { return nil }
    return CachedFile(fingerprint: fingerprintFor(dbPath), turns: [
        CachedTurn(timestamp: calls[0].timestamp, calls: calls),
    ])
}
