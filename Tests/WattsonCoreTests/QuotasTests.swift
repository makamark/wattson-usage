// QuotasTests.swift — server/tests/quotas.test.ts 的移植：多 provider 凭据解析、
// 响应归一化、隔离降级、QuotaPoller TTL、代理解析。全部网络走注入 fake fetch，不出网。
// fixtures 取自各平台真实接口响应结构（值脱敏）。
import XCTest
@testable import WattsonCore

/// 字典字面量 → JSON 路由（缩短 fixture 书写）
private func rt(_ any: Any) -> FakeRoute { .json(JSON.fromAny(any)) }

final class QuotasTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 进程级 OAuth client 缓存会把前一个用例的命中对带到后一个，先清空
        AntigravityClientCache.shared.resetForTests()
    }

    // MARK: - codex

    private let CODEX_OK = rt([
        "user_id": "user-x", "account_id": "acc-1", "plan_type": "team",
        "rate_limit": [
            "allowed": true, "limit_reached": false,
            "primary_window": ["used_percent": 16, "reset_after_seconds": 7788, "reset_at": 1_789_372_788.0],
            "secondary_window": ["used_percent": 2, "reset_after_seconds": 594588, "reset_at": 1_789_959_588.0],
        ],
        "rate_limit_reset_credits": ["available_count": 3, "applicable_available_count": 0],
    ])

    func testCodexAuthFileParsesAndFallsBackToJwtAccountId() {
        let home = makeTempDir(prefix: "qx-")
        let token = fakeJwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acc-jwt"]])
        writeFixture((home as NSString).appendingPathComponent(".codex/auth.json"),
                     JSON.fromAny(["auth_mode": "chatgpt", "tokens": ["access_token": token, "account_id": "acc-file"]]).encodedString())
        XCTAssertEqual(readCodexAuth(home, [:]), CodexAuth(token: token, accountId: "acc-file"))
        writeFixture((home as NSString).appendingPathComponent(".codex/auth.json"),
                     JSON.fromAny(["tokens": ["access_token": token]]).encodedString())
        XCTAssertEqual(readCodexAuth(home, [:])?.accountId, "acc-jwt")
    }

    func testCodexUsageNormalization() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["wham/usage": CODEX_OK], recorder: recorder)
        let acc = await fetchCodexAccount(CodexAuth(token: "t", accountId: "acc-1"), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "team")
        XCTAssertEqual(acc.windows.map(\.key), ["fiveHour", "week"])
        XCTAssertEqual(acc.windows[0].usedPercent, 16)
        XCTAssertEqual(acc.windows[0].nextResetAt, 1_789_372_788_000)
        XCTAssertEqual(acc.resetCredits, 3)
        XCTAssertEqual(acc.applicableResetCredits, 0)
        XCTAssertEqual(recorder.last()?.headers["chatgpt-account-id"], "acc-1")
        XCTAssertEqual(recorder.last()?.headers["authorization"], "Bearer t")
    }

    func testCodexUsageWithoutResetCreditsYieldsNulls() async {
        var obj = CODEX_OK.wrapped.obj ?? [:]
        obj.removeValue(forKey: "rate_limit_reset_credits")
        let fetch = fakeFetch(["wham/usage": rt(JSON.obj(obj))])
        let acc = await fetchCodexAccount(CodexAuth(token: "t", accountId: nil), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertNil(acc.resetCredits)
        XCTAssertNil(acc.applicableResetCredits)
    }

    func testCodexEnvCredentialsAndMissing() {
        let home = makeTempDir(prefix: "qx-")
        XCTAssertEqual(readCodexAuth(home, ["CODEX_ACCESS_TOKEN": " abc "]), CodexAuth(token: "abc", accountId: nil))
        XCTAssertNil(readCodexAuth(home, [:]))
    }

    func testExtractCodexAccountIdReturnsNilWithoutAuthClaim() {
        XCTAssertNil(extractCodexAccountId(fakeJwt(["sub": "x"])))
        XCTAssertNil(extractCodexAccountId("not-a-jwt"))
    }

    // MARK: - claude

    private let CLAUDE_OK = rt([
        "five_hour": ["utilization": 0.42, "resets_at": "2026-09-14T16:00:00Z"],
        "seven_day": ["utilization": 12, "resets_at": 1_789_959_588.0],
        "seven_day_sonnet": ["utilization": 3, "resets_at": 1_789_959_588.0],
    ])

    func testClaudeCredentialsFromOauthFileWithEnvPriority() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent(".claude/.credentials.json"),
                     JSON.fromAny(["claudeAiOauth": ["accessToken": "tok-file"]]).encodedString())
        XCTAssertEqual(readClaudeAuth(home, [:]), ClaudeAuth(token: "tok-file"))
        XCTAssertEqual(readClaudeAuth(home, ["CLAUDE_ACCESS_TOKEN": "tok-env"]), ClaudeAuth(token: "tok-env"))
    }

    func testClaudeUsageNormalizationUtilizationAndResets() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["/api/oauth/usage": CLAUDE_OK], recorder: recorder)
        let acc = await fetchClaudeAccount(ClaudeAuth(token: "t"), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.windows.map(\.key), ["fiveHour", "week", "weekSonnet"])
        XCTAssertEqual(acc.windows[0].usedPercent, 42)
        XCTAssertEqual(acc.windows[0].nextResetAt, parseJSDate("2026-09-14T16:00:00Z"))
        XCTAssertEqual(acc.windows[1].nextResetAt, 1_789_959_588_000)
        XCTAssertEqual(recorder.last()?.headers["anthropic-beta"], "oauth-2025-04-20")
    }

    // MARK: - cursor

    private let CURSOR_OK = rt([
        "startOfMonth": "2026-09-01T00:00:00.000Z",
        "membershipType": "pro",
        "prompts": ["secondary": ["usedPercentage": 33.3, "maxPercentage": 100, "resetDate": "2026-10-01T00:00:00.000Z"]],
    ])

    func testCursorWorkosCookieFromJwtSub() async {
        let token = fakeJwt(["sub": "user_abc"])
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["usage-summary": CURSOR_OK], recorder: recorder)
        let acc = await fetchCursorAccount(CursorAuth(token: token), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "pro")
        XCTAssertEqual(acc.windows.first?.key, "cycle")
        XCTAssertEqual(acc.windows.first?.usedPercent ?? -1, 33.3, accuracy: 1e-9)
        XCTAssertEqual(recorder.last()?.headers["cookie"], "WorkosCursorSessionToken=user_abc%3A%3A\(token)")
    }

    func testCursorNonJwtTokenErrorsAndFileCredentialsWork() async {
        let fetch = fakeFetch([:])
        let acc = await fetchCursorAccount(CursorAuth(token: "plain"), fetch, 1000)
        XCTAssertFalse(acc.available)
        XCTAssertTrue(acc.error?.contains("JWT") ?? false)
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent(".cursor/auth.json"),
                     JSON.fromAny(["accessToken": "tok"]).encodedString())
        XCTAssertEqual(readCursorAuth(home, [:]), CursorAuth(token: "tok"))
    }

    // MARK: - workbuddy（凭据路径已改为 ~/wattson/workbuddy-auth.json）

    private let WORKBUDDY_RESOURCE = rt([
        "code": 0,
        "data": ["Response": ["Data": ["Accounts": [[
            "CycleCapacitySize": 1000, "CycleCapacityUsed": 250, "CycleCapacityRemain": 750,
            "CapacityUnit": "credits", "CycleEndTime": "2026-10-01 00:00:00", "Unlimited": false,
        ]]]]],
    ])

    private var WORKBUDDY_BODY: JSON { WORKBUDDY_RESOURCE.wrapped }

    func testWorkbuddyWindowsFromTencentResource() {
        let ws = workbuddyWindows(resourceBody: WORKBUDDY_BODY)
        XCTAssertEqual(ws.count, 1)
        XCTAssertEqual(ws[0].key, "cycle")
        XCTAssertEqual(ws[0].total, 1000)
        XCTAssertEqual(ws[0].used, 250)
        XCTAssertEqual(ws[0].remaining, 750)
        XCTAssertEqual(ws[0].percentage ?? -1, 25, accuracy: 1e-9)
        XCTAssertEqual(ws[0].nextResetAt, parseJSDate("2026-10-01T00:00:00"))
    }

    func testWorkbuddyCredentialsFileAndEnvPaths() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent("wattson/workbuddy-auth.json"),
                     JSON.fromAny(["accessToken": "tok", "uid": "u1", "enterpriseId": "e1"]).encodedString())
        XCTAssertEqual(readWorkbuddyAuth(home, [:]),
                       WorkbuddyAuth(token: "tok", uid: "u1", enterpriseId: "e1", domain: nil))
        XCTAssertEqual(readWorkbuddyAuth(home, ["WORKBUDDY_ACCESS_TOKEN": "env-tok"]),
                       WorkbuddyAuth(token: "env-tok", uid: nil, enterpriseId: nil, domain: nil))
    }

    // MARK: - trae（凭据路径已改为 ~/wattson/trae-auth.json）

    private let TRAE_USAGE = rt([
        "code": 0,
        "user_entitlement_pack_list": [
            ["product_type": 3, "product_name": "其它包", "entitlement_base_info": ["end_time": 1_789_959_588.0]],
            ["product_type": 6, "product_name": "Pro 包", "entitlement_used": 120, "entitlement_total": 500,
             "entitlement_base_info": ["end_time": 1_789_959_588.0]],
        ],
    ])

    private var TRAE_BODY: JSON { TRAE_USAGE.wrapped }

    func testTraeWindowsPickMainPackByProductTypePriority() {
        let result = traeWindows(usageBody: TRAE_BODY)
        XCTAssertEqual(result.planName, "Pro 包")
        XCTAssertEqual(result.windows.count, 1)
        let w = result.windows[0]
        XCTAssertEqual(w.key, "cycle")
        XCTAssertEqual(w.total, 500)
        XCTAssertEqual(w.used, 120)
        XCTAssertNil(w.remaining)
        XCTAssertEqual(w.percentage ?? -1, 24, accuracy: 1e-9)
        XCTAssertEqual(w.nextResetAt, 1_789_959_588_000)
    }

    func testTraeCredentialsEnvAndFile() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent("wattson/trae-auth.json"),
                     JSON.fromAny(["accessToken": "tok", "region": "cn"]).encodedString())
        XCTAssertEqual(readTraeAuth(home, [:]), TraeAuth(token: "tok", region: "cn"))
        XCTAssertEqual(readTraeAuth(home, ["TRAE_ACCESS_TOKEN": "env"]), TraeAuth(token: "env", region: "intl"))
    }

    // MARK: - kimi

    private let KIMI_CODE_OK = rt([
        "usage": ["limit": "7000", "used": "1680", "remaining": "5320", "resetTime": "2026-09-15T00:00:00Z"],
        "limits": [["window": ["duration": 5, "timeUnit": "TIME_UNIT_HOUR"],
                    "detail": ["limit": "200", "used": "50", "remaining": "150", "reset_at": 1_789_959_588.0]]],
        "user": ["membership": ["level": "LEVEL_BASIC"]],
    ])

    func testKimiCredentialsEnvAndUnexpiredFile() {
        let home = makeTempDir(prefix: "qx-")
        let future = Date.nowMs() / 1000 + 3600
        let past = Date.nowMs() / 1000 - 3600
        writeFixture((home as NSString).appendingPathComponent(".kimi-code/credentials/kimi-code.json"),
                     JSON.fromAny(["access_token": "tok", "refresh_token": "r", "expires_at": future]).encodedString())
        XCTAssertEqual(readKimiAuth(home, [:])?.token, "tok")
        writeFixture((home as NSString).appendingPathComponent(".kimi-code/credentials/kimi-code.json"),
                     JSON.fromAny(["access_token": "tok", "expires_at": past]).encodedString())
        XCTAssertNil(readKimiAuth(home, [:]))
        XCTAssertEqual(readKimiAuth(home, ["KIMI_CODE_API_KEY": " env "]),
                       KimiAuth(token: "env", baseUrl: "https://api.kimi.com"))
    }

    func testKimiUsageNormalizationWeekAndRate() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["coding/v1/usages": KIMI_CODE_OK], recorder: recorder)
        let acc = await fetchKimiAccount(KimiAuth(token: "t", baseUrl: "https://api.kimi.com"), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "Moderato")
        let week = acc.windows[0]
        XCTAssertEqual(week.key, "week")
        XCTAssertEqual(week.total, 7000)
        XCTAssertEqual(week.used, 1680)
        XCTAssertEqual(week.remaining, 5320)
        XCTAssertEqual(week.percentage ?? -1, 24, accuracy: 1e-9)
        XCTAssertEqual(week.nextResetAt, parseJSDate("2026-09-15T00:00:00Z"))
        XCTAssertEqual(acc.windows[1].key, "rate")
        XCTAssertEqual(acc.windows[1].total, 200)
        XCTAssertEqual(acc.windows[1].used, 50)
        XCTAssertEqual(recorder.last()?.headers["x-msh-platform"], "kimi_code_cli")
        XCTAssertEqual(recorder.last()?.headers["authorization"], "Bearer t")
    }

    // MARK: - grok

    private let GROK_OK = rt([
        "config": [
            "creditUsagePercent": 41.5,
            "currentPeriod": ["end": "2026-10-01T00:00:00Z"],
            "onDemandCap": ["val": 100], "onDemandUsed": ["val": 10],
            "subscriptionTier": "supergrok_heavy",
        ],
    ])

    func testGrokAuthPrefersOidcScopeAndFlagsExpiry() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent(".grok/auth.json"),
                     JSON.fromAny([
                        "https://accounts.x.ai/sign-in": ["key": "legacy-tok"],
                        "https://auth.x.ai::oidc": ["key": "oidc-tok"],
                     ]).encodedString())
        XCTAssertEqual(readGrokAuth(home, [:]), GrokAuth(token: "oidc-tok", expired: false))
        let stale = ISO8601Format(ms: Date.nowMs() - 3600_000)
        writeFixture((home as NSString).appendingPathComponent(".grok/auth.json"),
                     JSON.fromAny(["https://auth.x.ai::oidc": ["key": "oidc-tok", "expires_at": stale]]).encodedString())
        XCTAssertTrue(readGrokAuth(home, [:])?.expired ?? false)
        XCTAssertEqual(readGrokAuth(home, ["GROK_OAUTH_TOKEN": " env "]), GrokAuth(token: "env", expired: false))
    }

    func testGrokBillingNormalizationAndPlanName() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["v1/billing": GROK_OK], recorder: recorder)
        let acc = await fetchGrokAccount(GrokAuth(token: "t", expired: false), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "SuperGrok Heavy")
        let w = acc.windows[0]
        XCTAssertEqual(w.key, "cycle")
        XCTAssertEqual(w.usedPercent ?? -1, 41.5, accuracy: 1e-9)
        XCTAssertEqual(w.nextResetAt, parseJSDate("2026-10-01T00:00:00Z"))
        XCTAssertEqual(recorder.last()?.headers["x-xai-token-auth"], "xai-grok-cli")
        XCTAssertTrue(recorder.urls[0].contains("format=credits"))
    }

    func testGrokExpiredCredentialsProduceErrorWithoutNetwork() async {
        let home = makeTempDir(prefix: "qx-")
        let stale = ISO8601Format(ms: Date.nowMs() - 3600_000)
        writeFixture((home as NSString).appendingPathComponent(".grok/auth.json"),
                     JSON.fromAny(["https://auth.x.ai::oidc": ["key": "t", "expires_at": stale]]).encodedString())
        let recorder = FetchRecorder()
        let fetch = fakeFetch([:], recorder: recorder)
        let acc = await grokAccount(home: home, env: [:], doFetch: fetch, now: Date.nowMs())
        XCTAssertFalse(acc.available)
        XCTAssertTrue(acc.error?.contains("过期") ?? false)
        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - copilot

    private let COPILOT_OK = rt([
        "copilot_plan": "individual",
        "quota_reset_date": "2026-10-01",
        "quota_snapshots": [
            "premium_interactions": ["entitlement": 300, "remaining": 210, "percent_remaining": 70],
            "chat": ["unlimited": true],
        ],
    ])

    func testCopilotSnapshotsNormalizationAndSpoofHeaders() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["copilot_internal/user": COPILOT_OK], recorder: recorder)
        let acc = await fetchCopilotAccount("gh-tok", fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "individual")
        XCTAssertEqual(acc.windows.map(\.key), ["premium"])
        let w = acc.windows[0]
        XCTAssertEqual(w.total, 300)
        XCTAssertEqual(w.remaining, 210)
        XCTAssertEqual(w.usedPercent ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(w.nextResetAt, parseJSDate("2026-10-01"))
        XCTAssertEqual(recorder.last()?.headers["authorization"], "token gh-tok")
        XCTAssertEqual(recorder.last()?.headers["editor-version"], "vscode/1.96.2")
        XCTAssertEqual(readCopilotAuth(["COPILOT_API_TOKEN": " t "]), "t")
    }

    // MARK: - openrouter

    func testOpenRouterCreditsAndOptionalKeyLimit() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch([
            "/credits": rt(["data": ["total_credits": 100, "total_usage": 37]]),
            "/key": rt(["data": ["limit": 50, "limit_remaining": 20, "usage": 30, "limit_reset": "monthly"]]),
        ], recorder: recorder)
        let acc = await fetchOpenRouterAccount((token: "t", baseUrl: "https://openrouter.ai/api/v1"), fetch, 1000)
        XCTAssertTrue(acc.available)
        let credits = acc.windows[0]
        XCTAssertEqual(credits.key, "credits")
        XCTAssertEqual(credits.total, 100)
        XCTAssertEqual(credits.used, 37)
        XCTAssertEqual(credits.remaining, 63)
        XCTAssertEqual(credits.percentage ?? -1, 37, accuracy: 1e-9)
        let limit = acc.windows[1]
        XCTAssertEqual(limit.key, "limit")
        XCTAssertEqual(limit.total, 50)
        XCTAssertEqual(limit.used, 30)
        XCTAssertEqual(limit.remaining, 20)
        XCTAssertEqual(recorder.last()?.headers["authorization"], "Bearer t")
    }

    func testOpenRouterEnvMissingAndBaseUrlOverride() {
        XCTAssertNil(readOpenRouterAuth([:]))
        let auth = readOpenRouterAuth(["OPENROUTER_API_KEY": "k", "OPENROUTER_API_URL": "https://proxy.example/v1/"])
        XCTAssertEqual(auth?.token, "k")
        XCTAssertEqual(auth?.baseUrl, "https://proxy.example/v1")
    }

    // MARK: - codebuff

    func testCodebuffCredentialsEnvAndNestedAuthToken() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent(".config/manicode/credentials.json"),
                     JSON.fromAny(["default": ["authToken": "nested"]]).encodedString())
        XCTAssertEqual(readCodebuffAuth(home, [:])?.token, "nested")
        writeFixture((home as NSString).appendingPathComponent(".config/manicode/credentials.json"),
                     JSON.fromAny(["authToken": "flat"]).encodedString())
        XCTAssertEqual(readCodebuffAuth(home, [:])?.token, "flat")
        XCTAssertEqual(readCodebuffAuth(home, ["CODEBUFF_API_KEY": "env"])?.token, "env")
    }

    func testCodebuffUsagePostAndSubscriptionRateLimitWindow() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch([
            "/api/v1/usage": rt(["usage": 120, "quota": 1000, "remainingBalance": 880, "next_quota_reset": "2026-10-01T00:00:00Z"]),
            "/api/user/subscription": rt(["subscription": ["displayName": "Pro", "status": "active"],
                                          "rateLimit": ["weeklyUsed": 40, "weeklyLimit": 200, "weeklyResetsAt": 1_789_959_588.0]]),
        ], recorder: recorder)
        let acc = await fetchCodebuffAccount(CodebuffAuth(token: "t", baseUrl: "https://www.codebuff.com"), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "Pro")
        let credits = acc.windows[0]
        XCTAssertEqual(credits.key, "credits")
        XCTAssertEqual(credits.total, 1000)
        XCTAssertEqual(credits.used, 120)
        XCTAssertEqual(credits.remaining, 880)
        XCTAssertEqual(credits.percentage ?? -1, 12, accuracy: 1e-9)
        XCTAssertEqual(credits.nextResetAt, parseJSDate("2026-10-01T00:00:00Z"))
        let week = acc.windows[1]
        XCTAssertEqual(week.key, "week")
        XCTAssertEqual(week.total, 200)
        XCTAssertEqual(week.used, 40)
        XCTAssertEqual(week.percentage ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(week.nextResetAt, 1_789_959_588_000)
        XCTAssertEqual(recorder.last(offset: 1)?.method, "POST")
        XCTAssertEqual(recorder.last(offset: 1)?.headers["authorization"], "Bearer t")
    }

    // MARK: - factory

    private let FACTORY_LIMITS = rt([
        "usesTokenRateLimitsBilling": true,
        "limits": [
            "standard": [
                "fiveHour": ["usedPercent": 22, "secondsRemaining": 3600],
                "weekly": ["usedPercent": 10, "windowEnd": "2026-09-21T00:00:00Z"],
                "monthly": ["usedPercent": 5, "windowEnd": 1_789_959_588.0],
            ],
            "core": NSNull(),
        ],
    ])

    func testFactoryCredentialsEnvAndDotEnvFile() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent(".factory/.env"),
                     "# comment\nexport FACTORY_API_KEY=\"fk-file\"\nOTHER=1\n")
        XCTAssertEqual(readFactoryApiKey(home, [:]), "fk-file")
        XCTAssertEqual(readFactoryApiKey(home, ["FACTORY_API_KEY": "fk-env"]), "fk-env")
    }

    func testFactoryBillingLimitsThreeWindowsAndExpiry() async {
        let now = parseJSDate("2026-09-14T12:00:00Z")!
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["/api/billing/limits": FACTORY_LIMITS], recorder: recorder)
        let acc = await fetchFactoryAccount("fk", fetch, now)
        XCTAssertTrue(acc.available)
        let w0 = acc.windows[0]
        XCTAssertEqual(w0.key, "fiveHour")
        XCTAssertEqual(w0.usedPercent ?? -1, 22, accuracy: 1e-9)
        XCTAssertEqual(w0.nextResetAt, now + 3600_000)
        XCTAssertEqual(acc.windows[1].key, "week")
        XCTAssertEqual(acc.windows[1].usedPercent ?? -1, 10, accuracy: 1e-9)
        XCTAssertEqual(acc.windows[1].nextResetAt, parseJSDate("2026-09-21T00:00:00Z"))
        XCTAssertEqual(acc.windows[2].key, "cycle")
        XCTAssertEqual(acc.windows[2].usedPercent ?? -1, 5, accuracy: 1e-9)
        XCTAssertEqual(acc.windows[2].nextResetAt, 1_789_959_588_000)
        XCTAssertTrue(recorder.urls[0].contains("https://api.factory.ai"))
        // 过期窗口：windowEnd 在过去且无 secondsRemaining → 0%
        let expired = fakeFetch(["/api/billing/limits": rt([
            "limits": ["standard": [
                "fiveHour": ["usedPercent": 99, "windowEnd": "2020-01-01T00:00:00Z"],
                "weekly": ["usedPercent": 1], "monthly": ["usedPercent": 1],
            ]],
        ])])
        let acc2 = await fetchFactoryAccount("fk", expired, now)
        XCTAssertEqual(acc2.windows[0].usedPercent, 0)
    }

    // MARK: - minimax

    private let MINIMAX_OK = rt([
        "data": [
            "base_resp": ["status_code": 0],
            "model_remains": [[
                "model_name": "abab-mini",
                "current_interval_total_count": 500, "current_interval_usage_count": 400,
                "current_interval_remaining_percent": 20, "end_time": 1_789_372_788.0,
                "current_weekly_total_count": 2000, "current_weekly_usage_count": 1000,
                "weekly_end_time": 1_789_959_588.0,
            ]],
        ],
    ])

    func testMiniMaxUsageCountIsRemainingNotUsed() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["token_plan/remains": MINIMAX_OK], recorder: recorder)
        let acc = await fetchMiniMaxAccount((token: "t", regions: [MiniMaxRegion(apiBase: "https://api.minimax.io")]), fetch, 1000)
        XCTAssertTrue(acc.available)
        let w0 = acc.windows[0]
        XCTAssertEqual(w0.key, "fiveHour")
        XCTAssertEqual(w0.total, 500)
        XCTAssertEqual(w0.used, 100)
        XCTAssertEqual(w0.remaining, 400)
        XCTAssertEqual(w0.percentage ?? -1, 20, accuracy: 1e-9)
        XCTAssertEqual(w0.nextResetAt, 1_789_372_788_000)
        XCTAssertEqual(acc.windows[1].key, "week")
        XCTAssertEqual(acc.windows[1].total, 2000)
        XCTAssertEqual(acc.windows[1].used, 1000)
        XCTAssertEqual(recorder.last()?.headers["mm-api-source"], "wattson-usage")
    }

    func testMiniMaxRegionFallbackIntlToCn() async {
        let recorder = FetchRecorder()
        let minimaxBody = MINIMAX_OK.wrapped
        let fetch: FetchLike = { req in
            recorder.append(req)
            if req.url.contains("minimax.io") {
                throw HTTPStatusError(status: 502, message: "HTTP 502")
            }
            return FetchResponse(status: 200, body: minimaxBody)
        }
        let acc = await fetchMiniMaxAccount(
            (token: "t", regions: [MiniMaxRegion(apiBase: "https://api.minimax.io"),
                                   MiniMaxRegion(apiBase: "https://api.minimaxi.com")]), fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertTrue(recorder.urls[0].contains("minimax.io"))
        // 国际区两条路径都失败后，才切到中国区
        XCTAssertTrue(recorder.urls[1].contains("minimax.io/v1/api/openplatform"))
        XCTAssertTrue(recorder.urls[2].contains("minimaxi.com"))
        let auth = readMiniMaxAuth(["MINIMAX_API_KEY": "k", "MINIMAX_REGION": "cn"])
        XCTAssertEqual(auth?.regions.first?.apiBase, "https://api.minimaxi.com")
    }

    // MARK: - antigravity

    /// go-keyring-base64 编码的 Keychain 原始输出（expiry 为带时区偏移的 ISO 串）
    private func keychainOutput(expiry: String) -> String {
        let payload: [String: Any] = [
            "token": ["access_token": "ya29.ag", "refresh_token": "1//ag-refresh", "expiry": expiry],
            "auth_method": "oauth",
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return "go-keyring-base64:" + data.base64EncodedString()
    }

    private let AG_SUMMARY = rt([
        "groups": [
            ["displayName": "Gemini Models", "buckets": [
                ["displayName": "Five Hour Limit Remaining", "remainingFraction": 1, "resetTime": "2026-09-17T12:00:00Z"],
                ["displayName": "Weekly Limit Remaining", "remainingFraction": 1],
            ]],
            ["displayName": "Claude and GPT models", "buckets": [
                ["displayName": "Five Hour Limit Remaining", "remaining": ["remainingFraction": 0.8165304]],
                ["displayName": "Weekly Limit Remaining", "remainingFraction": 0.9388435],
            ]],
        ],
    ])

    func testAntigravityKeychainOutputParsesAndRejectsGarbage() {
        let creds = parseAntigravityKeychainOutput(keychainOutput(expiry: "2026-09-17T02:20:06.001353+08:00"))
        XCTAssertEqual(creds?.accessToken, "ya29.ag")
        XCTAssertEqual(creds?.refreshToken, "1//ag-refresh")
        XCTAssertNotNil(creds?.expiryMs)
        XCTAssertNil(parseAntigravityKeychainOutput("not-base64-json"))
        XCTAssertNil(parseAntigravityKeychainOutput("go-keyring-base64:###"))
        let noRefresh = try! JSONSerialization.data(withJSONObject: ["token": ["access_token": "a"]])
        XCTAssertNil(parseAntigravityKeychainOutput(
            "go-keyring-base64:" + noRefresh.base64EncodedString()))
    }

    func testAntigravityEnvInjectionAndDisable() {
        let json = keychainOutput(expiry: "2026-09-17T02:20:06+08:00")
            .dropFirst("go-keyring-base64:".count)
        let decoded = String(data: Data(base64Encoded: String(json))!, encoding: .utf8)!
        XCTAssertEqual(readAntigravityCreds(["ANTIGRAVITY_KEYCHAIN_JSON": decoded])?.refreshToken, "1//ag-refresh")
        XCTAssertNil(readAntigravityCreds(["ANTIGRAVITY_KEYCHAIN_JSON": decoded, "ANTIGRAVITY_KEYCHAIN": "0"]))
        XCTAssertNil(readAntigravityCreds(["ANTIGRAVITY_KEYCHAIN_JSON": "{bad"]))
    }

    func testAntigravitySummaryNormalizationAndOrder() {
        let windows = parseAntigravityQuotaSummary(AG_SUMMARY.wrapped)
        XCTAssertEqual(windows.map(\.key), ["gemini-fiveHour", "gemini-week", "claude-fiveHour", "claude-week"])
        XCTAssertEqual(windows.map(\.label), ["Gemini 5小时", "Gemini 周额度", "Claude & GPT 5小时", "Claude & GPT 周额度"])
        XCTAssertEqual(windows[2].percentage ?? -1, (1 - 0.8165304) * 100, accuracy: 1e-9)
        XCTAssertEqual(windows[0].nextResetAt, 1_789_646_400_000)
        // 顶层 response 包裹（Connect-RPC 载荷）兼容
        XCTAssertEqual(parseAntigravityQuotaSummary(rt(["response": AG_SUMMARY.wrapped.obj!]).wrapped).count, 4)
        XCTAssertTrue(parseAntigravityQuotaSummary(.null).isEmpty)
    }

    func testAntigravityCloudFlowHappyPathAndRefresh() async {
        let fresh = AntigravityCreds(accessToken: "ya29.ag", refreshToken: "1//ag-refresh",
                                     expiryMs: 1000 + 3600_000)
        let recorder = FetchRecorder()
        let fetch = fakeFetch([
            "loadCodeAssist": rt(["planName": "Google AI Pro", "cloudaicompanionProject": "aicode-consumers"]),
            "retrieveUserQuotaSummary": AG_SUMMARY,
        ], recorder: recorder)
        let acc = await fetchAntigravityAccount(fresh, fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "Google AI Pro")
        XCTAssertEqual(acc.windows.count, 4)
        XCTAssertEqual(recorder.last()?.headers["authorization"], "Bearer ya29.ag")

        // 临期 + env 提供的 OAuth client → 先刷新再拉取
        let stale = AntigravityCreds(accessToken: "ya29.old", refreshToken: "1//ag-refresh",
                                     expiryMs: 1000 + 60_000,
                                     clientId: "env-client", clientSecret: "env-secret")
        let recorder2 = FetchRecorder()
        let fetch2 = fakeFetch([
            "oauth2.googleapis.com": rt(["access_token": "ya29.fresh", "expires_in": 3600]),
            "loadCodeAssist": rt(["planName": "Google AI Pro"]),
            "retrieveUserQuotaSummary": AG_SUMMARY,
        ], recorder: recorder2)
        let acc2 = await fetchAntigravityAccount(stale, env: [:], fetch2, 1000)
        XCTAssertTrue(acc2.available)
        XCTAssertTrue(recorder2.urls[0].contains("oauth2.googleapis.com/token"))
        XCTAssertEqual(recorder2.last()?.headers["authorization"], "Bearer ya29.fresh")
        // 请求体携带 env 提供的 client
        let form = recorder2.last(offset: 2)?.body ?? ""
        XCTAssertTrue(form.contains("client_id=env-client"))
    }

    func testAntigravityScanExtractsClientCandidatesFromBinary() {
        // 假值刻意不符合真实 id（12 位数字 + 32 位尾段）与真实 secret 长度，
        // 避免被当作真实凭据；NUL 模拟 Go 字符串常量 blob 的边界
        let nul = "\u{00}"
        let bin = Data([
            "junk", nul,
            "1234567-abc123def4.apps.googleusercontent.com", nul,
            "GOCSPX-fake-token000000000", nul, "https",
            "7654321-xyz987wvu.apps.googleusercontent.com",
            "GOCSPX-second0123456789012345", nul,
        ].joined().utf8)
        let found = scanOAuthCandidates(bin)
        XCTAssertTrue(found.ids.contains("1234567-abc123def4"))
        // id 前紧邻 "https" 字母串：后缀锚定正则仍能取出正确形态
        XCTAssertTrue(found.ids.contains("7654321-xyz987wvu"))
        XCTAssertTrue(found.secrets.contains("GOCSPX-fake-token000000000"))
        XCTAssertTrue(found.secrets.contains("GOCSPX-second0123456789012345"))
    }

    func testAntigravityRefreshTriesBinaryCandidatesAndCachesWinner() async {
        let creds = AntigravityCreds(accessToken: nil, refreshToken: "1//ag-refresh", expiryMs: nil,
                                     clientId: nil, clientSecret: nil)
        let recorder = FetchRecorder()
        let fetch: FetchLike = { req in
            recorder.append(req)
            if req.url.contains("oauth2.googleapis.com") {
                // 只有第一对候选（id1 + secret1）被 Google 接受，其余组合 400
                guard let body = req.body, body.contains("client_id=1234567-abc123def4"),
                      body.contains("client_secret=GOCSPX-fake-token000000000") else {
                    return FetchResponse(status: 400, body: .null)
                }
                return FetchResponse(status: 200, body: rt(["access_token": "ya29.from-candidate"]).wrapped)
            }
            if req.url.contains("loadCodeAssist") {
                return FetchResponse(status: 200, body: rt(["planName": "Google AI Pro"]).wrapped)
            }
            return FetchResponse(status: 200, body: self.AG_SUMMARY.wrapped)
        }
        let tmp = NSTemporaryDirectory() + "ag-bin-\(UUID().uuidString)"
        let bin = "1234567-abc123def4.apps.googleusercontent.com"
            + "GOCSPX-fake-token000000000"
            + "7654321-xyz987wvu.apps.googleusercontent.com"
            + "GOCSPX-second0123456789012345"
        try? bin.write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let acc = await fetchAntigravityAccount(
            creds, env: ["ANTIGRAVITY_APP_BIN": tmp],
            readFile: { try? Data(contentsOf: URL(fileURLWithPath: $0)) }, fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(recorder.last()?.headers["authorization"], "Bearer ya29.from-candidate")
        // 2 个 id × 2 个 secret = 4 对；第一对即命中 → 仅 1 次刷新请求
        let refreshCalls = recorder.all().filter { $0.url.contains("oauth2.googleapis.com") }
        XCTAssertEqual(refreshCalls.count, 1)
        XCTAssertTrue(refreshCalls[0].body?.contains("client_id=1234567-abc123def4") ?? false)
    }

    func testAntigravityQuotaFailureIsIsolatedAsError() async {
        let creds = AntigravityCreds(accessToken: "ya29.ag", refreshToken: "1//ag-refresh", expiryMs: nil)
        let fetch = fakeFetch([
            "loadCodeAssist": rt(["planName": "Google AI Pro"]),
            "retrieveUserQuotaSummary": .error(HTTPStatusError(status: 500, message: "HTTP 500")),
        ])
        let acc = await fetchAntigravityAccount(creds, fetch, 1000)
        XCTAssertFalse(acc.available)
        XCTAssertEqual(acc.unavailableReason, "http_error")
        XCTAssertNil(acc.lastSuccessAt)
    }

    // MARK: - zed

    private let ZED_OK = rt([
        "user": ["id": 42, "github_login": "octocat"],
        "plan": [
            "plan_v3": "zed_pro",
            "subscription_period": ["started_at": "2026-09-01T00:00:00Z", "ended_at": "2026-10-01T00:00:00Z"],
            "usage": ["edit_predictions": ["used": 300, "limit": 1000]],
        ],
    ])

    func testZedEnvCredentialsRequirePairAndNoKeychainByDefault() async {
        let noToken = await readZedAuth(["ZED_ACCESS_TOKEN": "t"])
        XCTAssertNil(noToken)
        let paired = await readZedAuth(["ZED_ACCESS_TOKEN": "t", "ZED_USER_ID": "42"])
        XCTAssertEqual(paired, ZedAuth(userId: "42", token: "t"))
        // 未显式 ZED_KEYCHAIN=1 时不碰钥匙串（注入的 run 若被调用会被记录）
        let spy = RunSpy()
        let result = await readZedAuth([:], run: spy.run)
        XCTAssertNil(result)
        XCTAssertEqual(spy.calls.count, 0)
    }

    func testZedUsersMeWindowsAndAuthHeader() async {
        let now = parseJSDate("2026-09-15T00:00:00Z")!
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["client/users/me": ZED_OK], recorder: recorder)
        let acc = await fetchZedAccount(ZedAuth(userId: "42", token: "t"), fetch, now)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "zed_pro")
        let w0 = acc.windows[0]
        XCTAssertEqual(w0.key, "editPredictions")
        XCTAssertEqual(w0.total, 1000)
        XCTAssertEqual(w0.used, 300)
        XCTAssertEqual(w0.remaining, 700)
        XCTAssertEqual(w0.percentage ?? -1, 30, accuracy: 1e-9)
        XCTAssertEqual(w0.nextResetAt, parseJSDate("2026-10-01T00:00:00Z"))
        // 账期 14/30 天 → ~46.7%
        XCTAssertEqual(acc.windows[1].key, "cycle")
        XCTAssertEqual(acc.windows[1].percentage ?? -1, 46.7, accuracy: 0.5)
        XCTAssertEqual(recorder.last()?.headers["authorization"], "42 t")
    }

    // MARK: - kiro

    private let KIRO_OK = rt([
        "usageBreakdownList": [[
            "resourceType": "CREDIT",
            "usageLimitWithPrecision": 100,
            "currentUsageWithPrecision": 45.5,
            "currentOveragesWithPrecision": 5.5,
            "nextDateReset": 1_789_959_588.0,
        ]],
    ])

    func testKiroCredentialsEnvPriorityAndInjectedSqlite() async {
        let home = makeTempDir(prefix: "qx-")
        let dataDir = (home as NSString).appendingPathComponent("kiro-cli-data")
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        writeFixture((dataDir as NSString).appendingPathComponent("data.sqlite3"), "not-a-real-db")
        let run: RunLike = { _, args in
            let sql = args.count > 2 ? args[2] : (args.last ?? "")
            if sql.contains("auth_kv") {
                let row = JSON.fromAny([["value": JSON.fromAny(["access_token": "tok"]).encodedString()]])
                return (stdout: row.encodedString(), stderr: "")
            }
            let row = JSON.fromAny([["value": JSON.fromAny(["arn": "arn:aws:codewhisperer:us-east-1:123:profile/default"]).encodedString()]])
            return (stdout: row.encodedString(), stderr: "")
        }
        let auth = await readKiroAuth(home, ["KIRO_DATA_DIR": dataDir], run: run)
        XCTAssertEqual(auth?.accessToken, "tok")
        XCTAssertEqual(auth?.profileArn, "arn:aws:codewhisperer:us-east-1:123:profile/default")
        let envAuth = await readKiroAuth(home, ["KIRO_ACCESS_TOKEN": "e", "KIRO_PROFILE_ARN": "arn"], run: run)
        XCTAssertEqual(envAuth, KiroAuth(accessToken: "e", profileArn: "arn"))
    }

    func testKiroArnEndpointMappingAndCreditOverage() async {
        XCTAssertEqual(kiroEndpointForArn("arn:aws:codewhisperer:us-east-1:123:profile/default"),
                       "https://codewhisperer.us-east-1.amazonaws.com/")
        XCTAssertEqual(kiroEndpointForArn("arn:aws:codewhisperer:eu-central-1:123:profile/default"),
                       "https://q.eu-central-1.amazonaws.com/")
        XCTAssertNil(kiroEndpointForArn("arn:aws:s3:::bucket"))
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["amazonaws.com": KIRO_OK], recorder: recorder)
        let acc = await fetchKiroAccount(
            KiroAuth(accessToken: "t", profileArn: "arn:aws:codewhisperer:us-east-1:123:profile/default"), fetch, 1000)
        XCTAssertTrue(acc.available)
        // planUsed = 45.5 - 5.5 = 40
        let w = acc.windows[0]
        XCTAssertEqual(w.key, "cycle")
        XCTAssertEqual(w.total, 100)
        XCTAssertEqual(w.used ?? -1, 40, accuracy: 1e-9)
        XCTAssertEqual(w.remaining, 60)
        XCTAssertEqual(w.percentage ?? -1, 40, accuracy: 1e-9)
        XCTAssertEqual(w.nextResetAt, 1_789_959_588_000)
        XCTAssertEqual(recorder.last()?.headers["x-amz-target"], "AmazonCodeWhispererService.GetUsageLimits")
        let reqBody = (try? JSON.parse(recorder.last()?.body ?? "{}"))
        XCTAssertEqual(reqBody?["profileArn"]?.str, "arn:aws:codewhisperer:us-east-1:123:profile/default")
    }

    // MARK: - gemini

    func testGeminiApiKeyModeYieldsNoCredentialsAndClientFromEnv() {
        let home = makeTempDir(prefix: "qx-")
        writeFixture((home as NSString).appendingPathComponent(".gemini/settings.json"),
                     JSON.fromAny(["security": ["auth": ["selectedType": "api-key"]]]).encodedString())
        writeFixture((home as NSString).appendingPathComponent(".gemini/oauth_creds.json"),
                     JSON.fromAny(["access_token": "t"]).encodedString())
        XCTAssertNil(readGeminiCreds(home, [:]))
        writeFixture((home as NSString).appendingPathComponent(".gemini/settings.json"),
                     JSON.fromAny(["security": ["auth": ["selectedType": "oauth-personal"]]]).encodedString())
        let creds = readGeminiCreds(home, ["GEMINI_OAUTH_CLIENT_ID": "cid", "GEMINI_OAUTH_CLIENT_SECRET": "csec"])
        XCTAssertEqual(creds?.accessToken, "t")
        XCTAssertEqual(creds?.clientId, "cid")
        XCTAssertEqual(creds?.clientSecret, "csec")
    }

    func testGeminiOAuthClientExtractedFromJsPath() {
        let home = makeTempDir(prefix: "qx-")
        let js = (home as NSString).appendingPathComponent("oauth2.js")
        writeFixture(js, "export const CLIENT_ID = \"cid-from-file\"\nexport const CLIENT_SECRET = \"csec-from-file\"\n")
        let client = extractOAuthClient(home, ["GEMINI_OAUTH2_JS_PATH": js])
        XCTAssertEqual(client?.clientId, "cid-from-file")
        XCTAssertEqual(client?.clientSecret, "csec-from-file")
    }

    func testGeminiSilentRefreshWritesBackCredsFile() async {
        let home = makeTempDir(prefix: "qx-")
        let credsPath = (home as NSString).appendingPathComponent(".gemini/oauth_creds.json")
        writeFixture(credsPath, JSON.fromAny(["access_token": "stale", "refresh_token": "r", "expiry_date": 1000]).encodedString())
        let recorder = FetchRecorder()
        let fetch = fakeFetch(["oauth2.googleapis.com": rt(["access_token": "fresh", "expires_in": 3600])], recorder: recorder)
        let creds = GeminiCreds(accessToken: "stale", refreshToken: "r", expiryMs: 1000,
                                clientId: "cid", clientSecret: "csec", credsPath: credsPath)
        let token = await ensureFreshAccessToken(creds, fetch, 1_000_000)
        XCTAssertEqual(token, "fresh")
        XCTAssertEqual(recorder.last()?.headers["content-type"], "application/x-www-form-urlencoded")
        let written = parseJSONFile(credsPath)
        XCTAssertEqual(written?["access_token"]?.str, "fresh")
        XCTAssertEqual(written?["expiry_date"]?.num, 1_000_000 + 3600_000)
    }

    func testGeminiQuotaBucketsPickLowestFractionPerModel() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch([
            "loadCodeAssist": rt(["currentTier": "standard-tier", "cloudaicompanionProject": "gen-lang-client-001"]),
            "retrieveUserQuota": rt(["buckets": [
                ["model_id": "gemini-2.5-pro", "remaining_fraction": 0.9, "reset_time": "2026-09-15T00:00:00Z", "token_type": "INPUT"],
                ["model_id": "gemini-2.5-pro", "remaining_fraction": 0.5, "reset_time": "2026-09-15T00:00:00Z", "token_type": "OUTPUT"],
                ["model_id": "gemini-2.5-flash", "remaining_fraction": 0.7, "reset_time": "2026-09-15T00:00:00Z", "token_type": "INPUT"],
            ]]),
        ], recorder: recorder)
        let creds = GeminiCreds(accessToken: "t", refreshToken: nil, expiryMs: nil,
                                clientId: nil, clientSecret: nil, credsPath: "/x")
        let acc = await fetchGeminiAccount(creds, fetch, 1000)
        XCTAssertTrue(acc.available)
        XCTAssertEqual(acc.planName, "Standard")
        XCTAssertEqual(acc.windows.map(\.key), ["gemini-2.5-pro", "gemini-2.5-flash"])
        XCTAssertEqual(acc.windows[0].usedPercent ?? -1, 50, accuracy: 1e-6)
        XCTAssertEqual(acc.windows[1].usedPercent ?? -1, 30, accuracy: 1e-6)
        let quotaReq = recorder.all().first { $0.url.contains("retrieveUserQuota") }
        let quotaBody = quotaReq.flatMap { try? JSON.parse($0.body ?? "{}") }
        XCTAssertEqual(quotaBody?["project"]?.str, "gen-lang-client-001")
    }

    // MARK: - QuotaPoller

    final class TimeBox: @unchecked Sendable {
        var t: Double
        init(_ t: Double) { self.t = t }
    }

    func testPollerIsolatesProvidersAndHonorsTtl() async {
        let box = TimeBox(1000)
        let recorder = FetchRecorder()
        let fetch = fakeFetch([
            "subscription/list": rt(["code": 200, "data": []]),
            "quota/limit": rt(["code": 200, "data": [
                "level": "pro",
                "limits": [["unit": 3, "number": 5, "usage": 100, "currentValue": 10, "remaining": 90, "percentage": 10, "nextResetTime": 2000.0]],
            ]]),
        ], recorder: recorder)
        let poller = QuotaPoller(
            home: "/nonexistent",
            env: ["ZCODE_BIGMODEL_USAGE_API_KEY": "glmkey00000000.abcdef000000", "CODEX_ACCESS_TOKEN": "codextoken"],
            fetchImpl: fetch,
            now: { box.t })
        let snap = await poller.current()
        let by = Dictionary(uniqueKeysWithValues: snap.accounts.map { ($0.kind, $0) })
        XCTAssertTrue(by[.glm]?.available ?? false)
        let glmWindow = by[.glm]?.windows.first
        XCTAssertEqual(glmWindow?.total, 100)
        XCTAssertEqual(glmWindow?.used, 10)
        XCTAssertEqual(glmWindow?.percentage ?? -1, 10, accuracy: 1e-9)
        XCTAssertFalse(by[.codex]?.available ?? true)
        // 无 HTTP 状态码的普通错误 → 归类为 error（而非 http_error）
        XCTAssertEqual(by[.codex]?.unavailableReason, "error")
        XCTAssertEqual(by[.claude]?.unavailableReason, "no_credentials")
        XCTAssertEqual(by[.trae]?.unavailableReason, "no_credentials")
        // TTL 内不重拉
        _ = await poller.current()
        let n = recorder.count
        box.t += PLAN_TTL_MS + 1
        _ = await poller.current()
        XCTAssertGreaterThan(recorder.count, n)
    }

    func testPollerAllMissingCredentialsYieldsSeventeenAccountsWithoutNetwork() async {
        let recorder = FetchRecorder()
        let fetch = fakeFetch([:], recorder: recorder)
        let poller = QuotaPoller(home: "/nonexistent", env: [:], fetchImpl: fetch)
        let snap = await poller.current()
        XCTAssertEqual(snap.accounts.count, 17)
        XCTAssertTrue(snap.accounts.allSatisfy { $0.unavailableReason == "no_credentials" })
        XCTAssertEqual(recorder.count, 0)
    }

    // MARK: - 代理

    func testParseScutilProxyOutput() {
        let out = [
            "  HTTPEnable : 1", "  HTTPPort : 7897", "  HTTPProxy : 127.0.0.1",
            "  HTTPSEnable : 1", "  HTTPSPort : 7897", "  HTTPSProxy : 127.0.0.1",
            "  SOCKSEnable : 0",
        ].joined(separator: "\n")
        let p = parseScutilProxy(out)
        XCTAssertEqual(p.httpsProxy, "http://127.0.0.1:7897")
        XCTAssertEqual(p.httpProxy, "http://127.0.0.1:7897")
    }

    func testResolveProxyUrlPriority() {
        XCTAssertEqual(resolveProxyUrl(env: ["HTTPS_PROXY": "http://x:1"], platform: "darwin", scutil: { "" }), "http://x:1")
        XCTAssertEqual(resolveProxyUrl(
            env: [:], platform: "darwin",
            scutil: { "HTTPSEnable : 1\nHTTPSProxy : 127.0.0.1\nHTTPSPort : 7897" }), "http://127.0.0.1:7897")
        XCTAssertNil(resolveProxyUrl(env: [:], platform: "darwin", scutil: { "HTTPSEnable : 0" }))
        XCTAssertNil(resolveProxyUrl(env: [:], platform: "linux", scutil: { "" }))
        let direct = createQuotaFetch(env: [:], platform: "darwin", scutil: { "HTTPSEnable : 0" })
        XCTAssertNil(direct.proxyUrl)
    }
}

final class RunSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, [String])] = []
    var calls: [(String, [String])] { lock.lock(); defer { lock.unlock() }; return _calls }

    func run(_ file: String, _ args: [String]) async throws -> (stdout: String, stderr: String) {
        lock.lock(); _calls.append((file, args)); lock.unlock()
        return (stdout: "", stderr: "")
    }
}
