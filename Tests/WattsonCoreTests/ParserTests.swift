// ParserTests.swift — 原生会话扫描管线测试（替代上游解析器套件的角色）：
// claude/codex JSONL fixture 扫描、zcode SQLite 投影读取、设备归属、
// 定价口径（billable/calculateCost）。
import XCTest
@testable import WattsonCore

final class ParserTests: XCTestCase {
    // MARK: claude（JSONL）

    func testClaudeJsonlScanProducesUsageRows() async {
        let home = makeTempDir(prefix: "scan-")
        let assistant: [String] = [
            JSON.fromAny([
                "type": "assistant", "sessionId": "s1", "cwd": "/Users/x/work",
                "timestamp": "2026-09-10T02:00:00.000Z",
                "message": ["model": "claude-sonnet-4-5",
                            "usage": ["input_tokens": 100, "output_tokens": 20,
                                      "cache_creation_input_tokens": 5, "cache_read_input_tokens": 50]],
            ]).encodedString(),
            JSON.fromAny(["type": "user", "message": "hello"]).encodedString(),
            JSON.fromAny([
                "type": "assistant", "sessionId": "s1", "cwd": "/Users/x/work",
                "timestamp": "2026-09-10T02:01:00.000Z",
                "message": ["model": "claude-sonnet-4-5",
                            "usage": ["input_tokens": 10, "output_tokens": 4]],
            ]).encodedString(),
        ]
        writeFixture((home as NSString).appendingPathComponent(".claude/projects/proj1/s1.jsonl"),
                     assistant.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 2)
        let r0 = rows[0]
        XCTAssertEqual(r0.tool, "claude")
        XCTAssertEqual(r0.host, "macair")
        XCTAssertEqual(r0.model, "claude-sonnet-4-5")
        XCTAssertEqual(r0.project, "/Users/x/work")
        XCTAssertEqual(r0.tin, 100)
        XCTAssertEqual(r0.tout, 20)
        XCTAssertEqual(r0.tcacheWrite, 5)
        XCTAssertEqual(r0.tcacheRead, 50)
        // costUSD 由聚合层重估，必有值且为估算
        XCTAssertGreaterThan(r0.cost ?? 0, 0)
        XCTAssertTrue(r0.costEstimated)
    }

    // MARK: codex（JSONL：逐事件增量 + 累计去重）

    /// 每个 token_count 事件按「自身时间戳」产生一行，而不是把会话累计值记到最后
    /// 一个事件的时间点。真实 codex 会话跨自然日长跑，取文件终值会把整天的工作量
    /// 塞到写入那天，逐日/逐时趋势与环比随之失真。
    func testCodexRolloutAttributesUsagePerEventTimestamp() async {
        let home = makeTempDir(prefix: "scan-")
        let events: [String] = [
            JSON.fromAny([
                "timestamp": "2026-09-10T01:00:00.000Z", "session_id": "c1",
                "payload": ["type": "session_meta", "cwd": "/Users/x/api"],
            ]).encodedString(),
            JSON.fromAny([
                "timestamp": "2026-09-10T01:05:00.000Z",
                "payload": ["type": "token_count",
                            "info": ["model_id": "gpt-5.2",
                                     "last_token_usage": ["input_tokens": 100, "cached_input_tokens": 20,
                                                          "output_tokens": 10, "reasoning_output_tokens": 4],
                                     "total_token_usage": ["input_tokens": 100, "cached_input_tokens": 20,
                                                           "output_tokens": 10, "reasoning_output_tokens": 4]]],
            ]).encodedString(),
            JSON.fromAny([
                "timestamp": "2026-09-11T02:10:00.000Z",
                "payload": ["type": "token_count",
                            "info": ["model_id": "gpt-5.2",
                                     "last_token_usage": ["input_tokens": 150, "cached_input_tokens": 30,
                                                          "output_tokens": 20, "reasoning_output_tokens": 6],
                                     "total_token_usage": ["input_tokens": 250, "cached_input_tokens": 50,
                                                           "output_tokens": 30, "reasoning_output_tokens": 10]]],
            ]).encodedString(),
        ]
        writeFixture((home as NSString).appendingPathComponent(".codex/sessions/2026/09/10/rollout-a.jsonl"),
                     events.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        // 两个事件 → 两行，各自落在自己的日期上（不是 1 行、也不是都落在 9/11）
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.project), ["/Users/x/api", "/Users/x/api"])
        let first = rows[0], second = rows[1]
        XCTAssertEqual(dayKey(first.ts), "2026-9-10")
        XCTAssertEqual(dayKey(second.ts), "2026-9-11")
        // 首事件 = 该事件自身的 last：input 100-20=80 fresh，cached 20，out 10
        XCTAssertEqual(first.tin, 80)
        XCTAssertEqual(first.tcacheRead, 20)
        XCTAssertEqual(first.tout, 10)
        XCTAssertEqual(first.treason, 4)
        // 次事件 = 自身 last（不是累计值）：input 150-30=120 fresh，cached 30，out 20
        XCTAssertEqual(second.tin, 120)
        XCTAssertEqual(second.tcacheRead, 30)
        XCTAssertEqual(second.tout, 20)
        XCTAssertGreaterThan(second.cost ?? 0, 0)
    }

    /// fork/resume 会原样重放父会话的累计事件（时间戳聚在 fork 创建点附近）：
    /// 相同累计值 + 相同明细必须只记一次，否则父会话支出被重复计费。
    func testCodexRolloutDedupesReplayedCumulativeEvents() async {
        let home = makeTempDir(prefix: "scan-")
        let cum: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 20,
                                  "output_tokens": 10, "reasoning_output_tokens": 4]
        let last: [String: Any] = ["input_tokens": 100, "cached_input_tokens": 20,
                                   "output_tokens": 10, "reasoning_output_tokens": 4]
        let events: [String] = [
            JSON.fromAny(["timestamp": "2026-09-10T01:00:00.000Z", "session_id": "c1",
                          "payload": ["type": "session_meta", "cwd": "/Users/x/f"]])
                .encodedString(),
            // 同一累计态被重述两次（重放）→ 只应记一次
            JSON.fromAny(["timestamp": "2026-09-10T01:05:00.000Z",
                          "payload": ["type": "token_count",
                                      "info": ["total_token_usage": cum, "last_token_usage": last]]])
                .encodedString(),
            JSON.fromAny(["timestamp": "2026-09-10T01:05:01.000Z",
                          "payload": ["type": "token_count",
                                      "info": ["total_token_usage": cum, "last_token_usage": last]]])
                .encodedString(),
        ]
        writeFixture((home as NSString).appendingPathComponent(".codex/sessions/2026/09/10/rollout-fork.jsonl"),
                     events.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 1, "重复累计态被记了多次：父会话支出被重复计费")
        XCTAssertEqual(rows[0].tout, 10)
    }

    /// 累计值缺失（老格式 / 仅给分项）时，必须由各分项求和兜底推进护栏，
    /// 否则「累计值未推进」判断会把首条之外的事件全部丢弃。
    func testCodexRolloutWithoutTotalTokensKeepsAllEvents() async {
        let home = makeTempDir(prefix: "scan-")
        let events: [String] = [
            JSON.fromAny(["timestamp": "2026-09-10T01:00:00.000Z", "session_id": "c3",
                          "payload": ["type": "session_meta", "cwd": "/Users/x/g"]]).encodedString(),
            JSON.fromAny(["timestamp": "2026-09-10T01:05:00.000Z",
                          "payload": ["type": "token_count",
                                      "info": ["model_id": "gpt-5.2",
                                               "total_token_usage": ["input_tokens": 100, "output_tokens": 10]]]])
                .encodedString(),
            JSON.fromAny(["timestamp": "2026-09-10T01:06:00.000Z",
                          "payload": ["type": "token_count",
                                      "info": ["model_id": "gpt-5.2",
                                               "total_token_usage": ["input_tokens": 300, "output_tokens": 40]]]])
                .encodedString(),
        ]
        writeFixture((home as NSString).appendingPathComponent(".codex/sessions/2026/09/10/rollout-nototal.jsonl"),
                     events.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 2, "缺 total_tokens 时只保留了首条事件")
        // 第二条走差分回退：input 300-100=200，output 40-10=30
        XCTAssertEqual(rows[1].tin, 200)
        XCTAssertEqual(rows[1].tout, 30)
    }

    /// 回归：真实 rollout 的 payload.model 只在会话开头出现（用量行在后），
    /// 解析器必须跨行保留模型名，否则整批用量落成 unknown（曾致 4.28B tokens 无价）
    func testCodexRolloutKeepsModelFromSessionHeaderLine() async {
        let home = makeTempDir(prefix: "scan-")
        let events: [String] = [
            JSON.fromAny([
                "timestamp": "2026-09-10T01:00:00.000Z", "session_id": "c2",
                "payload": ["type": "session_meta", "cwd": "/Users/x/app", "model_provider": "openai", "model": "gpt-5.5"],
            ]).encodedString(),
            JSON.fromAny([
                "timestamp": "2026-09-10T01:05:00.000Z",
                "payload": ["type": "token_count",
                            "info": ["total_token_usage": ["input_tokens": 100, "cached_input_tokens": 20,
                                                           "output_tokens": 10, "reasoning_output_tokens": 2]]],
            ]).encodedString(),
        ]
        writeFixture((home as NSString).appendingPathComponent(".codex/sessions/2026/09/10/rollout-b.jsonl"),
                     events.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].model, "gpt-5.5")   // 不是 unknown
        XCTAssertEqual(rows[0].project, "/Users/x/app")
        XCTAssertEqual(rows[0].tout, 10)
        XCTAssertEqual(rows[0].treason, 2)
    }

    // MARK: claude（去重 / subagents）

    /// 流式重述：同一条 assistant 消息（同 message.id）会被反复写出，每次带一份
    /// 累计 usage；不去重就是把这些快照叠加成一笔重复支出。
    func testClaudeDeduplicatesRestatedMessageIds() async {
        let home = makeTempDir(prefix: "scan-")
        func assistant(_ id: String, input: Double, output: Double, ts: String) -> String {
            JSON.fromAny([
                "type": "assistant", "sessionId": "s1", "cwd": "/Users/x/dedup", "timestamp": ts,
                "message": ["id": id, "model": "claude-sonnet-4-5",
                            "usage": ["input_tokens": input, "output_tokens": output]],
            ]).encodedString()
        }
        let lines = [
            assistant("msg_1", input: 100, output: 20, ts: "2026-09-10T02:00:00.000Z"),
            // 同 id 重述（流式快照）→ 不得再记一次
            assistant("msg_1", input: 100, output: 20, ts: "2026-09-10T02:00:01.000Z"),
            assistant("msg_2", input: 10, output: 4, ts: "2026-09-10T02:01:00.000Z"),
        ]
        writeFixture((home as NSString).appendingPathComponent(".claude/projects/proj1/s1.jsonl"),
                     lines.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 2, "同 message.id 的流式重述被重复计费")
        XCTAssertEqual(rows.reduce(0.0) { $0 + $1.tin }, 110)
    }

    /// 子代理记录在 `<slug>/<session>/subagents/**`（workflow 再深一层）：
    /// 只扫一层会把子代理产生的真实花费整批漏掉。
    func testClaudeScansNestedSubagentTranscripts() async {
        let home = makeTempDir(prefix: "scan-")
        func assistant(_ model: String, input: Double, ts: String) -> String {
            JSON.fromAny([
                "type": "assistant", "sessionId": "s1", "cwd": "/Users/x/sub", "timestamp": ts,
                "message": ["id": model + ts, "model": model,
                            "usage": ["input_tokens": input, "output_tokens": 5]],
            ]).encodedString()
        }
        let root = (home as NSString).appendingPathComponent(".claude/projects/proj2")
        writeFixture(root + "/s1.jsonl", assistant("claude-sonnet-4-5", input: 100, ts: "2026-09-10T02:00:00.000Z"))
        writeFixture(root + "/s1/subagents/agent-a.jsonl",
                     assistant("claude-haiku-4-5", input: 30, ts: "2026-09-10T02:02:00.000Z"))
        writeFixture(root + "/s1/subagents/workflows/wf1/agent-b.jsonl",
                     assistant("claude-haiku-4-5", input: 7, ts: "2026-09-10T02:03:00.000Z"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 3, "子代理 transcript 未被扫描")
        XCTAssertEqual(rows.reduce(0.0) { $0 + $1.tin }, 137)
    }

    /// 缓存写 1 小时档单价更高：只读 legacy 总量会把 1h 档按 5 分钟价计
    func testClaudeExtractsOneHourCacheWriteAndWebSearch() async {
        let home = makeTempDir(prefix: "scan-")
        let line = JSON.fromAny([
            "type": "assistant", "sessionId": "s1", "cwd": "/Users/x/cache", "timestamp": "2026-09-10T02:00:00.000Z",
            "message": ["id": "msg_c", "model": "claude-sonnet-4-5",
                        "usage": ["input_tokens": 100, "output_tokens": 10,
                                  "cache_creation_input_tokens": 40,
                                  "cache_creation": ["ephemeral_5m_input_tokens": 10,
                                                     "ephemeral_1h_input_tokens": 30],
                                  "server_tool_use": ["web_search_requests": 2]]],
        ]).encodedString()
        writeFixture((home as NSString).appendingPathComponent(".claude/projects/proj3/s1.jsonl"), line)
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].tcacheWrite, 40)
        // 1h 档 30 tokens 按 1.6× 计，5m 档 10 tokens 按 1.25× 计
        //（claude-sonnet-4-5 输入 $3/M、缓存写 $3.75/M，与 1.25×输入一致）
        let expectedCache = 10 * 3.75e-6 + 30 * 3.75e-6 * 1.6
        XCTAssertEqual(rows[0].cost ?? 0, 100 * 3e-6 + 10 * 15e-6 + expectedCache + 2 * 0.01, accuracy: 1e-12)
    }

    // MARK: workbuddy（SQLite：会话级估算，须带 model/cwd）

    // MARK: zcode（SQLite 投影，经系统 sqlite3）

    func testZcodeSqliteScanSkipsZeroRowsAndSplitsCachedInput() async throws {
        let home = makeTempDir(prefix: "scan-")
        let db = (home as NSString).appendingPathComponent(".zcode/cli/db/db.sqlite")
        writeFixture(db, "")
        let sql = """
        CREATE TABLE session(id TEXT, directory TEXT);
        CREATE TABLE model_usage(session_id TEXT, turn_id TEXT, model_id TEXT,
            input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
            cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER,
            started_at INTEGER, completed_at INTEGER);
        INSERT INTO session VALUES('s1', '/Users/x/billing');
        INSERT INTO model_usage VALUES('s1', 't1', 'glm-5.2', 1000, 100, 20, 200, 300, 1789959588, 1789959600);
        INSERT INTO model_usage VALUES('s1', 't2', 'glm-5.2', 0, 0, 0, 0, 0, 1789959601, 1789959602);
        """
        _ = try await runProcess("sqlite3", [db, sql])
        let cache = await scanAllSources(home: home, devices: [], run: { try await runProcess($0, $1) })
        let rows = rowsFromCache(cache, [], "macair")
        // 全 0 行跳过
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.tool, "zcode")
        XCTAssertEqual(r.project, "/Users/x/billing")
        // fresh input = 1000 - 300 - 200 = 500
        XCTAssertEqual(r.tin, 500)
        XCTAssertEqual(r.tcacheRead, 300)
        XCTAssertEqual(r.tcacheWrite, 200)
        XCTAssertEqual(r.tout, 100)
        XCTAssertEqual(r.treason, 20)
        // zcode 源在解析期定价（calculateCost），聚合层不再重估
        XCTAssertFalse(r.costEstimated)
        XCTAssertGreaterThan(r.cost ?? 0, 0)
    }

    /// workbuddy 必须带出 model 与 cwd：缺 model 会让成本恒为 $0（模型名都在价目表里），
    /// 缺 cwd 则无法按项目切片；已删除会话（deleted_at 非空）不得继续计费。
    func testWorkbuddyScanKeepsModelAndProjectAndSkipsDeleted() async throws {
        let home = makeTempDir(prefix: "scan-")
        let db = (home as NSString).appendingPathComponent(".workbuddy/workbuddy.db")
        writeFixture(db, "")
        let sql = """
        CREATE TABLE sessions(id TEXT, cwd TEXT, model TEXT, deleted_at INTEGER);
        CREATE TABLE session_usage(session_id TEXT, used INTEGER, updated_at INTEGER);
        INSERT INTO sessions VALUES('w1', '/Users/x/proj', 'glm-5.3-flash', NULL);
        INSERT INTO sessions VALUES('w2', '/Users/x/local', 'custom-local:deepseek-v4', NULL);
        INSERT INTO sessions VALUES('w3', '/Users/x/gone', 'hy3', 1788000000000);
        INSERT INTO session_usage VALUES('w1', 1000, 1787800173023);
        INSERT INTO session_usage VALUES('w2', 500, 1787800215243);
        INSERT INTO session_usage VALUES('w3', 9999, 1787800300000);
        """
        _ = try await runProcess("sqlite3", [db, sql])
        let cache = await scanAllSources(home: home, devices: [], run: { try await runProcess($0, $1) })
        let rows = rowsFromCache(cache, [], "macair")
        XCTAssertEqual(rows.count, 2, "已删除会话仍在计费")
        let byModel = Dictionary(uniqueKeysWithValues: rows.map { ($0.model, $0) })
        XCTAssertNotNil(byModel["glm-5.3-flash"], "model 丢失（落成 unknown）：成本会被归零")
        XCTAssertEqual(byModel["glm-5.3-flash"]?.project, "Users-x-proj")
        // custom-local: 前缀剥离后再计价
        XCTAssertNotNil(byModel["deepseek-v4"])
        // used 是会话级 token 总量，记在输入侧（记成输出会污染模型明细两列）
        XCTAssertEqual(byModel["glm-5.3-flash"]?.tin, 1000)
        XCTAssertEqual(byModel["glm-5.3-flash"]?.tout, 0)
        XCTAssertGreaterThan(byModel["glm-5.3-flash"]?.cost ?? 0, 0)
    }

    /// fork 复述：新文件带 forked_from_id 并复述父文件的事件。
    /// 父文件在场时复述必须只计一次（键在父 id 命名空间里相撞，总数 385 就是重复计费）；
    /// 父文件缺席时复述必须照常计入——不能靠时间戳截断无条件丢数据。
    func testCodexForkReplayIsDedupedAgainstPresentParentOnly() async {
        func meta(_ sid: String, _ fork: String?, _ ts: String) -> String {
            var payload: [String: Any] = ["type": "session_meta", "cwd": "/Users/x/fork", "session_id": sid]
            if let fork { payload["forked_from_id"] = fork }
            return JSON.fromAny(["timestamp": ts, "session_id": sid, "payload": payload]).encodedString()
        }
        // last_token_usage 是「本次事件增量」，与累计值独立
        func tc(_ ts: String, _ input: Double, _ output: Double) -> String {
            JSON.fromAny(["timestamp": ts,
                          "payload": ["type": "token_count",
                                      "info": ["model_id": "gpt-5.2",
                                               "last_token_usage": ["input_tokens": input, "output_tokens": output],
                                               "total_token_usage": ["input_tokens": input, "output_tokens": output,
                                                                     "total_tokens": input + output]]]]).encodedString()
        }
        // 父文件在场：父 100/10 + fork 复述同一事件 + fork 新做 150/15
        // → 唯一用量 = 110（复述只算一次）+ 165 = 275；若不去重则是 385
        let homeA = makeTempDir(prefix: "fork-a-")
        let dirA = (homeA as NSString).appendingPathComponent(".codex/sessions/2026/09/10")
        writeFixture(dirA + "/rollout-parent.jsonl",
                     [meta("p1", nil, "2026-09-10T01:00:00.000Z"), tc("2026-09-10T01:05:00.000Z", 100, 10)]
                        .joined(separator: "\n"))
        writeFixture(dirA + "/rollout-fork.jsonl",
                     [meta("f1", "p1", "2026-09-11T01:00:00.000Z"),
                      tc("2026-09-11T01:00:01.000Z", 100, 10),      // 复述父事件
                      tc("2026-09-11T01:10:00.000Z", 150, 15)].joined(separator: "\n"))  // fork 新工作
        let cacheA = await scanAllSources(home: homeA, devices: [], run: failingRun)
        let rowsA = rowsFromCache(cacheA, [], "macair")
        XCTAssertEqual(rowsA.reduce(0.0) { $0 + $1.tin + $1.tout }, 275,
                       "复述未被去重（385 = 父事件被记两次）或被过度丢弃")
        XCTAssertEqual(rowsA.count, 2, "复述事件应被丢弃一次，只留父事件与 fork 新工作")

        // 父文件缺席：只有 fork 文件时复述不得被丢弃（键不相撞，照常计入）
        let homeB = makeTempDir(prefix: "fork-b-")
        let dirB = (homeB as NSString).appendingPathComponent(".codex/sessions/2026/09/11")
        writeFixture(dirB + "/rollout-fork.jsonl",
                     [meta("f2", "absent-parent", "2026-09-11T01:00:00.000Z"),
                      tc("2026-09-11T01:00:01.000Z", 100, 10),
                      tc("2026-09-11T01:10:00.000Z", 150, 15)].joined(separator: "\n"))
        let cacheB = await scanAllSources(home: homeB, devices: [], run: failingRun)
        let rowsB = rowsFromCache(cacheB, [], "macair")
        XCTAssertEqual(rowsB.reduce(0.0) { $0 + $1.tin + $1.tout }, 275,
                       "父文件缺席时仍丢弃了复述：这些 token 无人计入")
        XCTAssertEqual(rowsB.count, 2, "父文件缺席时复述必须保留")
    }

    // MARK: 增量缓存（指纹未变则复用）

    /// 未变更的文件必须复用上一轮结果（codex 会话目录数百 MB，每轮重读是分钟级开销），
    /// 变更后必须重新解析。复用靠指纹，因此指纹必须真的被读取。
    func testUnchangedFilesAreReusedByFingerprint() async {
        let home = makeTempDir(prefix: "incr-")
        let path = (home as NSString).appendingPathComponent(".claude/projects/p/s1.jsonl")
        func line(_ id: String, _ input: Double) -> String {
            JSON.fromAny(["type": "assistant", "cwd": "/Users/x/incr", "timestamp": "2026-09-10T02:00:00.000Z",
                          "message": ["id": id, "model": "claude-sonnet-4-5",
                                      "usage": ["input_tokens": input, "output_tokens": 1]]]).encodedString()
        }
        writeFixture(path, line("m1", 100))
        let first = await scanAllSources(home: home, devices: [], run: failingRun)
        let firstFile = first.providers["claude"]?.files[path]
        XCTAssertNotNil(firstFile)

        // 第二轮：文件未变 → 复用同一份 CachedFile 值
        let second = await scanAllSources(home: home, devices: [], run: failingRun, previous: first)
        XCTAssertEqual(second.providers["claude"]?.files[path], firstFile)
        XCTAssertEqual(rowsFromCache(second, [], "h").count, 1)

        // 写入新内容（mtime/size 变化）→ 指纹失效，必须重新解析出两条
        writeFixture(path, [line("m1", 100), line("m2", 7)].joined(separator: "\n"))
        let third = await scanAllSources(home: home, devices: [], run: failingRun, previous: second)
        XCTAssertEqual(rowsFromCache(third, [], "h").count, 2)
    }

    /// resume 场景：新建的会话文件复述旧（未变更）文件里的 message.id。
    /// 复用旧文件时必须回种去重集合，否则旧支出被按新文件再记一遍。
    func testResumedSessionDoesNotDoubleCountReusedFileMessages() async {
        let home = makeTempDir(prefix: "resume-")
        let root = (home as NSString).appendingPathComponent(".claude/projects/p")
        func line(_ id: String, _ input: Double) -> String {
            JSON.fromAny(["type": "assistant", "cwd": "/Users/x/r", "timestamp": "2026-09-10T02:00:00.000Z",
                          "message": ["id": id, "model": "claude-sonnet-4-5",
                                      "usage": ["input_tokens": input, "output_tokens": 1]]]).encodedString()
        }
        // 旧会话：m1
        writeFixture(root + "/old.jsonl", line("m1", 100))
        let first = await scanAllSources(home: home, devices: [], run: failingRun)
        XCTAssertEqual(rowsFromCache(first, [], "h").count, 1)

        // resume 新建新文件：复述 m1，并新增 m2
        writeFixture(root + "/new.jsonl", [line("m1", 100), line("m2", 5)].joined(separator: "\n"))
        let second = await scanAllSources(home: home, devices: [], run: failingRun, previous: first)
        let rows = rowsFromCache(second, [], "h")
        XCTAssertEqual(rows.count, 2, "resume 复述的 m1 被重复计费")
        XCTAssertEqual(rows.reduce(0.0) { $0 + $1.tin }, 105)
    }

    // MARK: 设备归属

    func testMirrorSourceAttributedToRemoteHost() async throws {
        let home = makeTempDir(prefix: "scan-")
        let mirrorRoot = (makeTempDir(prefix: "mirror-") as NSString).appendingPathComponent("macpro")
        let db = (mirrorRoot as NSString).appendingPathComponent("zcode/db.sqlite")
        writeFixture(db, "")
        let sql = """
        CREATE TABLE session(id TEXT, directory TEXT);
        CREATE TABLE model_usage(session_id TEXT, turn_id TEXT, model_id TEXT,
            input_tokens INTEGER, output_tokens INTEGER, reasoning_tokens INTEGER,
            cache_creation_input_tokens INTEGER, cache_read_input_tokens INTEGER,
            started_at INTEGER, completed_at INTEGER);
        INSERT INTO session VALUES('s9', '/remote/dir');
        INSERT INTO model_usage VALUES('s9', 't1', 'glm-5.2', 10, 5, 0, 0, 0, 1789959588, 1789959589);
        """
        _ = try await runProcess("sqlite3", [db, sql])
        let cache = await scanAllSources(home: home,
                                         devices: [DeviceRoot(host: "macpro", zcodeDb: db)],
                                         run: { try await runProcess($0, $1) })
        let rows = rowsFromCache(cache, [DeviceRoot(host: "macpro", zcodeDb: db)], "macair")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].host, "macpro")
    }

    // MARK: 定价口径

    func testBillableOutputTokensDeduplicatesReasoningInOutputProviders() {
        XCTAssertEqual(billableOutputTokens(provider: "codex", outputTokens: 50, reasoningTokens: 20), 50)
        XCTAssertEqual(billableOutputTokens(provider: "claude", outputTokens: 50, reasoningTokens: 20), 50)
        XCTAssertEqual(billableOutputTokens(provider: "copilot", outputTokens: 50, reasoningTokens: 20), 50)
        XCTAssertEqual(billableOutputTokens(provider: "zcode", outputTokens: 50, reasoningTokens: 20), 70)
    }

    func testCalculateCostKnownModel() {
        // glm-5.2: input 1e-6, output 3.2e-6, cacheRead 0.1e-6，cacheWrite 缺省 1.25×input
        let cost = calculateCost(model: "glm-5.2", inputTokens: 100, outputTokens: 15,
                                 cacheCreationTokens: 10, cacheReadTokens: 50)
        let expected = 100 * 1e-6 + 15 * 3.2e-6 + 10 * 1.25e-6 + 50 * 0.1e-6
        XCTAssertEqual(cost, expected, accuracy: 1e-12)
    }

    func testCalculateCostUnknownModelIsZeroNotMissing() {
        XCTAssertEqual(calculateCost(model: "totally-unknown-model", inputTokens: 1000,
                                     outputTokens: 100, cacheCreationTokens: 0, cacheReadTokens: 0), 0)
    }

    func testCalculateCostIgnoresNegativeAndNonFiniteInputs() {
        let c = calculateCost(model: "glm-5.2", inputTokens: -5, outputTokens: .nan,
                              cacheCreationTokens: -1, cacheReadTokens: .infinity)
        XCTAssertEqual(c, 0)
    }

    func testCalculateCostDateSuffixedModelFallsBackToBase() {
        let base = calculateCost(model: "gpt-5.2", inputTokens: 100, outputTokens: 10,
                                 cacheCreationTokens: 0, cacheReadTokens: 0)
        let dated = calculateCost(model: "gpt-5.2-20260101", inputTokens: 100, outputTokens: 10,
                                  cacheCreationTokens: 0, cacheReadTokens: 0)
        XCTAssertEqual(dated, base)
    }

    private var failingRun: RunLike {
        { file, _ in throw TestError("测试不应调用外部命令：\(file)") }
    }
}
