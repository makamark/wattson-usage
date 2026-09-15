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

    // MARK: codex（JSONL：累计值取终值）

    func testCodexRolloutScanTakesFinalCumulativeUsage() async {
        let home = makeTempDir(prefix: "scan-")
        let events: [String] = [
            JSON.fromAny([
                "timestamp": "2026-09-10T01:00:00.000Z", "session_id": "c1",
                "payload": ["type": "session_meta", "cwd": "/Users/x/api"],
            ]).encodedString(),
            JSON.fromAny([
                "timestamp": "2026-09-10T01:05:00.000Z",
                "payload": ["type": "token_count",
                            "info": ["model_id": "gpt-5.2", "total_token_usage": ["input_tokens": 100, "cached_input_tokens": 20,
                                                           "output_tokens": 10, "reasoning_output_tokens": 4]]],
            ]).encodedString(),
            JSON.fromAny([
                "timestamp": "2026-09-10T01:10:00.000Z",
                "payload": ["type": "token_count",
                            "info": ["model_id": "gpt-5.2", "total_token_usage": ["input_tokens": 250, "cached_input_tokens": 50,
                                                           "output_tokens": 30, "reasoning_output_tokens": 10]]],
            ]).encodedString(),
        ]
        writeFixture((home as NSString).appendingPathComponent(".codex/sessions/2026/09/10/rollout-a.jsonl"),
                     events.joined(separator: "\n"))
        let cache = await scanAllSources(home: home, devices: [], run: failingRun)
        let rows = rowsFromCache(cache, [], "macair")
        // 只取每文件终值，防 resume/fork 内重复计费
        XCTAssertEqual(rows.count, 1)
        let r = rows[0]
        XCTAssertEqual(r.tool, "codex")
        XCTAssertEqual(r.project, "/Users/x/api")
        // codex 的 input_tokens 已含 cached：拆出 fresh input
        XCTAssertEqual(r.tin, 200)
        XCTAssertEqual(r.tcacheRead, 50)
        XCTAssertEqual(r.tout, 30)
        XCTAssertEqual(r.treason, 10)
        XCTAssertGreaterThan(r.cost ?? 0, 0)
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
