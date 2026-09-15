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

/// 全量扫描全部数据源。指纹未变的文件直接复用上一轮解析结果——
/// 本机 codex 会话目录可达数百 MB，每轮重读全部 JSONL 是分钟级开销，
/// 而绝大部分文件在两个采集节拍之间并无变化。
public func parseAllSessions(home: String = homePath(),
                             devices: [DeviceRoot] = loadDeviceRoots(),
                             run: RunLike = runProcess) async throws {
    let previous = SessionStore.shared.get()
    let cache = await scanAllSources(home: home, devices: devices, run: run, previous: previous)
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
                           run: RunLike = runProcess,
                           previous: SessionCache? = nil) async -> SessionCache {
    var providers: [String: ProviderSection] = [:]
    // 上一轮各 provider 的文件表：指纹相同即复用（未变文件零解析）
    let prev = previous?.providers ?? [:]

    // ---------- claude ----------
    let claudeRoots: [String] = [(home as NSString).appendingPathComponent(".claude/projects")]
    var files: [String: CachedFile] = [:]
    for root in claudeRoots {
        for (path, calls) in parseClaudeProject(root, previous: prev["claude"]?.files ?? [:]) {
            files[path] = calls
        }
    }
    if !files.isEmpty { providers["claude"] = ProviderSection(envFingerprint: "native", files: files) }
    // ---------- codex ----------
    var codexFiles: [String: CachedFile] = [:]
    var codexRoots: [String] = [(home as NSString).appendingPathComponent(".codex")]
    codexRoots.append(contentsOf: devices.compactMap(\.codexHome))
    // 去重集合跨全部 codex 根共享：fork 文件可能与父文件分处本机与镜像两棵树
    var seenCodex = Set<String>()
    for root in codexRoots {
        for (path, file) in parseCodexSessions(root, previous: prev["codex"]?.files ?? [:], seen: &seenCodex) {
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
        if let reused = reusedFile(db, prev["zcode"]?.files ?? [:], key: "\(db):sessions") {
            zcodeFiles["\(db):sessions"] = reused
        } else if let file = await parseZcodeDatabase(db, run: run) {
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
        if let reused = reusedFile(db, prev["workbuddy"]?.files ?? [:], key: "\(db):sessions") {
            wbFiles["\(db):sessions"] = reused
        } else if let file = await parseWorkbuddyDatabase(db, run: run) {
            wbFiles["\(db):sessions"] = file
        }
    }
    if !wbFiles.isEmpty { providers["workbuddy"] = ProviderSection(envFingerprint: "native", files: wbFiles) }
    return SessionCache(version: 9, complete: true, providers: providers)
}

/// 指纹未变的文件直接复用上一轮结果（nil = 需重新解析）
func reusedFile(_ path: String, _ prevFiles: [String: CachedFile], key: String) -> CachedFile? {
    guard let cached = prevFiles[key], let fp = cached.fingerprint, !cached.turns.isEmpty else { return nil }
    guard let current = fingerprintFor(path), current == fp else { return nil }
    return cached
}

// MARK: - claude（JSONL：assistant 条目 message.usage）

func parseClaudeProject(_ projectsDir: String,
                        previous: [String: CachedFile] = [:]) -> [(path: String, file: CachedFile)] {
    var out: [(String, CachedFile)] = []
    // 跨文件去重集合：同一条 assistant 消息可能被同项目的多个会话文件重述
    //（resume/fork 共享 message.id），按文件各记一次就会重复计费
    var seenMsgIds = Set<String>()
    for slug in listDirectory(projectsDir) {
        let dir = (projectsDir as NSString).appendingPathComponent(slug)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue else { continue }
        for path in collectClaudeJsonl(dir) {
            // 未变更文件复用上一轮结果，但必须先用它的去重键回种集合：
            // resume 新建的会话文件会复述旧文件里的 assistant 消息，
            // 不回种就会把旧支出按新文件再记一遍。
            if let reused = reusedFile(path, previous, key: path) {
                for turn in reused.turns {
                    for call in turn.calls where call.dedupKey != nil {
                        seenMsgIds.insert(call.dedupKey!)
                    }
                }
                out.append((path, reused))
                continue
            }
            if let file = parseClaudeSessionFile(path, slug: slug, seenMsgIds: &seenMsgIds) {
                out.append((path, file))
            }
        }
    }
    return out
}

/// 递归收集会话文件：`<slug>/*.jsonl` 之外，Claude Code 的子代理记录在
/// `<slug>/<session>/subagents/**/*.jsonl`（workflow 再深一层 `subagents/workflows/`），
/// 只扫一层会把子代理真实花费全部漏掉。
func collectClaudeJsonl(_ dir: String, depth: Int = 0) -> [String] {
    guard depth <= 4 else { return [] }
    var out: [String] = []
    for name in listDirectory(dir) {
        let path = (dir as NSString).appendingPathComponent(name)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
            out.append(contentsOf: collectClaudeJsonl(path, depth: depth + 1))
        } else if name.hasSuffix(".jsonl") {
            out.append(path)
        }
    }
    return out
}

/// 单个 claude 会话文件 → CachedFile；无可用用量行返回 nil
private func parseClaudeSessionFile(_ path: String, slug: String,
                                    seenMsgIds: inout Set<String>) -> CachedFile? {
    guard let raw = readDataFile(path) else { return nil }
    var calls: [CachedCall] = []
    var fileMsgIds = Set<String>()
    let mAssistant = Data("\"assistant\"".utf8)
    let mUsage = Data("\"usage\"".utf8)
    forEachLine(raw) { line in
        // 预过滤：只解析同时含 assistant 与 usage 标记的行（绝大多数行直接跳过）
        guard line.range(of: mAssistant) != nil, line.range(of: mUsage) != nil else { return }
        guard let entry = try? JSON.parse(line) else { return }
        guard entry["type"]?.str == "assistant" || entry["type"] == nil else { return }
        guard let usageNode = entry["message"]?["usage"], usageNode.obj != nil else { return }
        let ts = entry["timestamp"]?.str ?? ""
        // 流式重复条目：同一条 assistant 消息会被反复重述，每次重述都带一份累计
        // usage，不去重就是把这些快照叠加。按 message.id 双重重去重（文件内 + 跨文件）；
        // 无 id 的记录退回「时间戳」键，与无 id 时的原始口径一致。
        let msgId = entry["message"]?["id"]?.str ?? entry["message"]?["message_id"]?.str
            ?? entry["messageId"]?.str ?? entry["id"]?.str
        let key = msgId ?? "claude:\(ts)"
        if fileMsgIds.contains(key) { return }
        fileMsgIds.insert(key)
        if seenMsgIds.contains(key) { return }
        seenMsgIds.insert(key)
        // project 优先取条目 cwd，回退目录 slug
        let project = entry["cwd"]?.str ?? slug
        // 缓存写：1 小时档单价更高；只读 legacy 总量会把 1h 档按 5 分钟价计
        let cacheCreation = claudeCacheCreation(usageNode)
        let webSearch = aggNum(usageNode["server_tool_use"]?["web_search_requests"])
        calls.append(CachedCall(
            model: entry["message"]?["model"]?.str,
            usage: CachedUsage(
                inputTokens: aggNum(usageNode["input_tokens"]),
                outputTokens: aggNum(usageNode["output_tokens"]),
                cacheCreationInputTokens: cacheCreation.total,
                cacheReadInputTokens: aggNum(usageNode["cache_read_input_tokens"]),
                reasoningTokens: aggNum(usageNode["reasoning_tokens"]),
                webSearchRequests: webSearch,
                cacheCreationOneHourTokens: cacheCreation.oneHour),
            timestamp: ts,
            project: project,
            dedupKey: key))
    }
    guard !calls.isEmpty else { return nil }
    return CachedFile(fingerprint: fingerprintFor(path), turns: [
        CachedTurn(timestamp: calls[0].timestamp, calls: calls),
    ])
}

/// claude 缓存写拆分：legacy 总量 vs 5m/1h 分档，取较大者当总量
///（畸形分档不得丢 token），1h 档不超过总量。
func claudeCacheCreation(_ usage: JSON) -> (total: Double, oneHour: Double) {
    let legacyTotal = aggNum(usage["cache_creation_input_tokens"])
    let cacheCreation = usage["cache_creation"]
    let fiveMinute = aggNum(cacheCreation?["ephemeral_5m_input_tokens"])
    let oneHour = aggNum(cacheCreation?["ephemeral_1h_input_tokens"])
    let splitTotal = fiveMinute + oneHour
    if splitTotal == 0 { return (legacyTotal, 0) }
    let total = max(legacyTotal, splitTotal)
    return (total, min(oneHour, total))
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

func parseCodexSessions(_ codexHome: String,
                        previous: [String: CachedFile] = [:],
                        seen: inout Set<String>) -> [(path: String, file: CachedFile)] {
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
        // 未变更文件零解析（codex 会话目录可达数百 MB，重读是分钟级开销），
        // 但必须把它的去重键回种到全局集合：fork 文件会复述父文件的事件，
        // 不回种则父文件（已复用）与新 fork 文件会被各记一次
        if let reused = reusedFile(path, previous, key: path) {
            for turn in reused.turns {
                for call in turn.calls where call.dedupKey != nil { seen.insert(call.dedupKey!) }
            }
            out[path] = reused
        } else if let file = parseCodexRollout(path, seen: &seen) {
            out[path] = file
        }
    }
    return out.map { ($0.key, $0.value) }
}

/// codex rollout → 每个 token_count 事件一条调用，按事件自身时间戳记账。
/// 只取文件终值会把整个会话的累计量塞到最后一次写入的那一天，逐日/逐时趋势与
/// 环比就系统性失真（实测长会话跨多自然日，涉及约 44% 的 codex token）。
/// fork/resume 会把父会话的整段事件历史复述进新文件，故用「累计值 + 累计明细」
/// 合成去重键、并以父会话 id 作命名空间，让复述事件与父文件的原事件在全量集合里
/// 相撞而被丢弃一次。这套做法是自平衡的：父文件不在数据集时键不会相撞，
/// 复述照常计入——不像按时间截断那样无条件丢数据。
func parseCodexRollout(_ path: String, seen: inout Set<String>) -> CachedFile? {
    guard let raw = readDataFile(path) else { return nil }
    var calls: [CachedCall] = []
    var sessionModel: String?
    var project: String?
    var sessionId: String?
    var forkedFromId = ""
    /// 累计总量哨兵：nil = 尚未见过事件（首个事件必定放行，
    /// 否则「从不报累计值」的会话会丢掉开场那次用量）
    var prevCumulativeTotal: Double?
    var prevInput = 0.0, prevCached = 0.0, prevCacheWrite = 0.0
    var prevOutput = 0.0, prevReasoning = 0.0
    var fileSeen = Set<String>()
    let mTokenCount = Data("\"token_count\"".utf8)
    let mSessionMeta = Data("\"session_meta\"".utf8)
    let mModel = Data("\"model\"".utf8)
    let mCwd = Data("\"cwd\"".utf8)
    // 预过滤分两档：token_count（用量）/ session_meta（会话元数据）/ 含 model|cwd 的元数据行。
    // 真实 rollout 的 payload.model（如 gpt-5.5）只在会话开头出现，必须一并捕获，
    // 否则用量行无法归属到模型（曾整批落成 unknown）。
    forEachLine(raw) { line in
        let isTokenCount = line.range(of: mTokenCount) != nil
        let isSessionMeta = line.range(of: mSessionMeta) != nil
        let maybeMeta = line.range(of: mModel) != nil || line.range(of: mCwd) != nil
        guard isTokenCount || isSessionMeta || maybeMeta else { return }
        guard let entry = try? JSON.parse(line) else { return }
        let payload = entry["payload"]
        if let sid = entry["session_id"]?.str ?? payload?["session_id"]?.str { sessionId = sid }
        if let cwd = payload?["cwd"]?.str ?? entry["cwd"]?.str { project = cwd }
        if isSessionMeta, let fork = payload?["forked_from_id"]?.str, !fork.isEmpty {
            forkedFromId = fork
        }
        // 模型名：payload.model（标准）→ 其它历史/变体字段
        let payloadModel = payload?["model"]?.str ?? payload?["model_id"]?.str
            ?? payload?["info"]?["model_id"]?.str
            ?? payload?["collaboration_mode"]?["settings"]?["model"]?.str
            ?? entry["model"]?.str
        if let m = payloadModel { sessionModel = m }
        guard isTokenCount else { return }
        let ts = entry["timestamp"]?.str ?? ""
        guard let infoObj = payload?["info"]?.obj else { return }
        // 形状兼容：total/last 可能在 payload.info 或直接挂在 payload/顶层
        let totalNode = infoObj["total_token_usage"] ?? payload?["total_token_usage"] ?? entry["total_token_usage"]
        let lastNode = infoObj["last_token_usage"] ?? payload?["last_token_usage"] ?? entry["last_token_usage"]
        // 累计总量：优先 total_tokens，缺失时由各分项求和兜底。
        // 兜底很关键——若 cumulativeTotal 恒为 0，下面的「累计值未推进」护栏会把
        // 每个文件的第一个事件之外全部丢掉（只认首条），整批用量被静默吞掉。
        let cumulativeTotal = totalNode.map { t -> Double in
            let explicit = aggNum(t["total_tokens"])
            if explicit > 0 { return explicit }
            return aggNum(t["input_tokens"]) + aggNum(t["cached_input_tokens"])
                + aggNum(t["output_tokens"]) + aggNum(t["reasoning_output_tokens"])
        } ?? 0
        // 重复的累计值 = 字节级重放，直接丢弃（首个事件靠 nil 哨兵放行）
        if let prev = prevCumulativeTotal, cumulativeTotal == prev { return }
        prevCumulativeTotal = cumulativeTotal

        var input = 0.0, cached = 0.0, cacheWrite = 0.0, output = 0.0, reasoning = 0.0
        if let last = lastNode?.obj {
            input = aggNum(last["input_tokens"])
            cached = aggNum(last["cached_input_tokens"])
            cacheWrite = aggNum(last["cache_write_input_tokens"])
            output = aggNum(last["output_tokens"])
            reasoning = aggNum(last["reasoning_output_tokens"])
        } else if cumulativeTotal > 0, let t = totalNode?.obj {
            input = aggNum(t["input_tokens"]) - prevInput
            cached = aggNum(t["cached_input_tokens"]) - prevCached
            cacheWrite = aggNum(t["cache_write_input_tokens"]) - prevCacheWrite
            output = aggNum(t["output_tokens"]) - prevOutput
            reasoning = aggNum(t["reasoning_output_tokens"]) - prevReasoning
        }
        // prev 计数器必须始终跟随累计值：只在回退分支更新的话，混用 last/no-last
        // 的会话下一轮差分会拿陈旧基线，把整个累计窗口重复计一遍。
        if let t = totalNode?.obj {
            prevInput = aggNum(t["input_tokens"])
            prevCached = aggNum(t["cached_input_tokens"])
            prevCacheWrite = aggNum(t["cache_write_input_tokens"])
            prevOutput = aggNum(t["output_tokens"])
            prevReasoning = aggNum(t["reasoning_output_tokens"])
        }
        if input + cached + output + reasoning == 0 { return }

        let model = payloadModel ?? sessionModel ?? "unknown"
        // OpenAI 口径：cached 已含在 input 里，拆出非缓存输入按输入价计
        let uncachedInput = max(0, input - cached)
        // 缓存写从非缓存输入里划出（不是叠加），钳零防滞后计数把输入桶压成负数；
        // 仅当价目表公布了明确缓存写单价时才划出——否则 1.25× 的兜底倍率会凭空
        // 造出一笔 OpenAI 从未收取的附加费，这些 token 留在普通输入里按原价计。
        let clampedCacheWrite = max(0, min(cacheWrite, uncachedInput))
        let billedCacheWrite = clampedCacheWrite > 0 && cacheWriteCostIsExplicit(model) ? clampedCacheWrite : 0
        let billedInput = uncachedInput - billedCacheWrite
        // 去重键：命名空间用父会话 id（fork 复述与父文件原事件相撞），
        // 并以「累计值 + 累计明细」区分——真复述必定全等，而 fork 后真正新做的
        // 工作即使累计值巧合相同、明细也不同，不会被误吞
        let dedupKey = "codex:\(forkedFromId.isEmpty ? (sessionId ?? path) : forkedFromId):\(numKey(cumulativeTotal))"
            + ":\(numKey(aggNum(totalNode?["input_tokens"]))):\(numKey(aggNum(totalNode?["cached_input_tokens"])))"
            + ":\(numKey(aggNum(totalNode?["output_tokens"]))):\(numKey(aggNum(totalNode?["reasoning_output_tokens"])))"
        if seen.contains(dedupKey) || fileSeen.contains(dedupKey) { return }
        fileSeen.insert(dedupKey)
        seen.insert(dedupKey)

        let billableOutput = billableOutputTokens(provider: "codex", outputTokens: output, reasoningTokens: reasoning)
        calls.append(CachedCall(
            model: model,
            usage: CachedUsage(inputTokens: billedInput, outputTokens: output,
                               cacheCreationInputTokens: billedCacheWrite,
                               cacheReadInputTokens: cached, reasoningTokens: reasoning),
            costUSD: calculateCost(model: model, inputTokens: billedInput, outputTokens: billableOutput,
                                   cacheCreationTokens: billedCacheWrite, cacheReadTokens: cached),
            timestamp: ts,
            project: project,
            dedupKey: dedupKey))
    }
    guard !calls.isEmpty else { return nil }
    return CachedFile(fingerprint: fingerprintFor(path), turns: [
        CachedTurn(timestamp: calls[0].timestamp, sessionId: sessionId, calls: calls),
    ])
}

/// 数值键格式化（去小数点，保证同值同键）
func numKey(_ n: Double) -> String {
    n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int64(n)) : String(n)
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
    // model/cwd 必须一起取：缺了 model 成本恒为 $0、缺了 cwd 无法按项目切片；
    // deleted_at IS NULL 排除已删除会话（否则历史删除的会话仍在计费）
    let rows = await sqliteJSONRows(run, dbPath, """
        SELECT su.session_id as session_id, su.used as used, su.updated_at as updated_at,
               s.model as model, s.cwd as cwd
        FROM session_usage su JOIN sessions s ON s.id = su.session_id
        WHERE su.used > 0 AND s.deleted_at IS NULL
        """)
    guard !rows.isEmpty else { return nil }
    var calls: [CachedCall] = []
    for row in rows {
        guard let used = row["used"]?.num, used > 0 else { continue }
        calls.append(CachedCall(
            model: normalizeWorkbuddyModel(row["model"]?.str),
            // session_usage.used 是该会话的 token 总量，口径上属于输入侧；
            // 记成输出会污染模型明细的输入/输出两列
            usage: CachedUsage(inputTokens: used),
            timestamp: toEpochMs(row["updated_at"]).map { ISO8601Format(ms: $0) } ?? "",
            project: row["cwd"]?.str.flatMap(sanitizeWorkbuddyProject)))
    }
    guard !calls.isEmpty else { return nil }
    return CachedFile(fingerprint: fingerprintFor(dbPath), turns: [
        CachedTurn(timestamp: calls[0].timestamp, calls: calls),
    ])
}

/// workbuddy 的 model 可能带内部命名空间前缀（custom-local:xxx）
func normalizeWorkbuddyModel(_ raw: String?) -> String {
    guard let raw, !raw.isEmpty else { return "unknown" }
    return raw.hasPrefix("custom-local:") ? String(raw.dropFirst("custom-local:".count)) : raw
}

/// cwd → 项目名（去掉前导 / 并把 / 换成 -，与设备侧口径一致）
func sanitizeWorkbuddyProject(_ cwd: String) -> String? {
    guard !cwd.isEmpty else { return nil }
    let trimmed = cwd.hasPrefix("/") ? String(cwd.dropFirst()) : cwd
    let slug = trimmed.replacingOccurrences(of: "/", with: "-")
    return slug.isEmpty ? nil : slug
}

