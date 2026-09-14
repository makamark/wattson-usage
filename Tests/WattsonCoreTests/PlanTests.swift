// PlanTests.swift — server/tests/plan.test.ts 的移植：解密回环、响应归一化、错误降级。
import XCTest
@testable import WattsonCore

final class PlanTests: XCTestCase {
    /// 与生产 readCodingPlanAuth 完全同口径的密钥构造（平台/用户名取真实值）
    private func secretForHome(_ home: String) -> String {
        credentialSecret(home: home, platform: "darwin", user: NSUserName(), env: [:])
    }

    private let HOME = "/Users/tester"
    private var SECRET: String { credentialSecret(home: "/Users/tester", platform: "darwin", user: "/Users/tester", env: [:]) }

    private let AUTH = CodingPlanAuth(authorization: "k", host: "https://bigmodel.cn",
                                      provider: "bigmodel-individual-coding-plan")

    private let QUOTA_OK = jsonDict([
        "code": 200, "msg": "操作成功", "success": true,
        "data": [
            "level": "pro",
            "limits": [
                ["type": "CREDIT_LIMIT", "unit": 3, "number": 5, "usage": 12000, "currentValue": 734, "remaining": 11265, "percentage": 6, "nextResetTime": 1_789_369_217_511.0],
                ["type": "CREDIT_LIMIT", "unit": 6, "number": 1, "usage": 60000, "currentValue": 22702, "remaining": 37297, "percentage": 37, "nextResetTime": 1_789_526_193_988.0],
            ],
        ],
    ])

    private let SUB_OK = jsonDict([
        "code": 200, "msg": "操作成功", "success": true,
        "data": [[
            "id": "907377", "productId": "product-f176ba", "productName": "GLM Coding Pro",
            "status": "VALID", "valid": "2026-12-09 10:00:00-2027-03-09 10:00:00",
            "autoRenew": 0, "billingCycle": "quarterly", "nextRenewTime": "2026-12-09",
            "inCurrentPeriod": true,
        ]],
    ])

    // MARK: 凭据解密

    func testEncryptDecryptRoundTrip() {
        let secret = "unit-test-secret"
        let enc = encryptCredential("2255beabcdef1234.nDOl00000000", secret: secret)!
        XCTAssertEqual(decryptCredential(enc, secret: secret), "2255beabcdef1234.nDOl00000000")
    }

    func testWrongSecretOrBadFormatReturnsNilNotThrow() {
        let enc = encryptCredential("some.key-value", secret: "right-secret")!
        XCTAssertNil(decryptCredential(enc, secret: "wrong-secret"))
        XCTAssertNil(decryptCredential("enc:v1:garbage", secret: SECRET))
        XCTAssertEqual(decryptCredential("plain-value", secret: SECRET), "plain-value")
    }

    func testNormalizeApiKeyStripsBearerAndExtractsIdDotSecret() {
        XCTAssertEqual(normalizeApiKey("Bearer 2255beabcdef1234.nDOl00000000"), "2255beabcdef1234.nDOl00000000")
        XCTAssertEqual(normalizeApiKey("junk-prefix 2255beabcdef1234.nDOl00000000 suffix"), "2255beabcdef1234.nDOl00000000")
        XCTAssertEqual(normalizeApiKey("short.k"), "short.k")
    }

    // MARK: readCodingPlanAuth

    func testReadsIndividualCodingPlanKeyFromCredentials() throws {
        let home = makeTempDir(prefix: "plan-home-")
        let v2 = (home as NSString).appendingPathComponent(".zcode/v2")
        try FileManager.default.createDirectory(atPath: v2, withIntermediateDirectories: true)
        let secret = secretForHome(home)
        let entry = "account-provider:coding-plan:account:bigmodel-individual-coding-plan:account:77431772783280681:api-key"
        let teamEntry = "account-provider:coding-plan:account:bigmodel-team-coding-plan:account:77431772783280681:api-key"
        let cred: [String: Any] = [
            teamEntry: encryptCredential("teamkey00000000.deadbeef0000", secret: secret)!,
            entry: encryptCredential("2255beabcdef1234.nDOl00000000", secret: secret)!,
            "zcodejwttoken": encryptCredential("not-a-key", secret: secret)!,
        ]
        writeFixture((v2 as NSString).appendingPathComponent("credentials.json"),
                     String(data: try JSONSerialization.data(withJSONObject: cred), encoding: .utf8)!)
        let auth = readCodingPlanAuth(home, [:])
        XCTAssertNotNil(auth)
        XCTAssertEqual(auth?.provider, "bigmodel-individual-coding-plan")
        XCTAssertEqual(auth?.host, "https://bigmodel.cn")
        XCTAssertEqual(auth?.authorization, "2255beabcdef1234.nDOl00000000")
    }

    func testZaiFamilyProviderRoutesToZcodeZai() throws {
        let home = makeTempDir(prefix: "plan-home-")
        let v2 = (home as NSString).appendingPathComponent(".zcode/v2")
        try FileManager.default.createDirectory(atPath: v2, withIntermediateDirectories: true)
        let secret = secretForHome(home)
        let entry = "account-provider:coding-plan:account:zai-individual-coding-plan:account:1:api-key"
        let cred = [entry: encryptCredential("zaikey00000000.cafe00000000", secret: secret)!]
        writeFixture((v2 as NSString).appendingPathComponent("credentials.json"),
                     String(data: try JSONSerialization.data(withJSONObject: cred), encoding: .utf8)!)
        XCTAssertEqual(readCodingPlanAuth(home, [:])?.host, "https://zcode.z.ai")
    }

    func testMissingCredentialsReturnsNilAndEnvKeyWins() throws {
        let empty = makeTempDir(prefix: "plan-empty-")
        XCTAssertNil(readCodingPlanAuth(empty, [:]))
        let auth = readCodingPlanAuth(HOME, ["ZCODE_BIGMODEL_USAGE_API_KEY": "envkey00000000.abcdef000000"])
        XCTAssertEqual(auth?.provider, "env:bigmodel-usage")
        XCTAssertEqual(auth?.authorization, "envkey00000000.abcdef000000")
    }

    // MARK: parsePlanWindows / parseSubscription

    func testParsePlanWindowsOrdersFiveHourFirstThenWeek() {
        let limits = QUOTA_OK["data"]?["limits"]
        let ws = parsePlanWindows(limits)
        XCTAssertEqual(ws.map(\.key), ["fiveHour", "week"])
        XCTAssertEqual(ws.map(\.label), ["5 小时窗口", "周额度"])
        let w0 = ws[0]
        XCTAssertEqual(w0.total, 12000)
        XCTAssertEqual(w0.used, 734)
        XCTAssertEqual(w0.remaining, 11265)
        XCTAssertEqual(w0.percentage ?? -1, 6)
        XCTAssertEqual(w0.nextResetAt ?? -1, 1_789_369_217_511)
        XCTAssertEqual(ws[1].percentage ?? -1, 37)
    }

    func testParsePlanWindowsToleratesUnknownUnitsAndBadRows() {
        // 与 TS 相同的数组输入：未知 unit、null 行、坏 usage 行
        let items: JSON = .arr([
            .obj(["unit": .num(9), "number": .num(2), "usage": .num(10), "currentValue": .num(1)]),
            .null,
            .obj(["usage": .str("x")]),
        ])
        let ws = parsePlanWindows(items)
        XCTAssertEqual(ws.count, 1)
        XCTAssertEqual(ws[0].key, "unit-9")
        XCTAssertEqual(parsePlanWindows(nil), [])
    }

    func testParseSubscriptionPicksCurrentPeriodValidRow() {
        let s = parseSubscription(SUB_OK)
        XCTAssertEqual(s.planName, "GLM Coding Pro")
        XCTAssertEqual(s.billingCycle, "quarterly")
        XCTAssertEqual(s.validFrom, "2026-12-09 10:00:00")
        XCTAssertEqual(s.validTo, "2027-03-09 10:00:00")
        XCTAssertEqual(s.autoRenew, false)
        XCTAssertEqual(s.nextRenewAt, "2026-12-09")
    }

    // MARK: fetchPlanSnapshot

    func testBothEndpointsSuccessYieldAvailableSnapshot() async {
        let fetch = fakeFetch([
            "subscription/list": .json(SUB_OK),
            "quota/limit": .json(QUOTA_OK),
        ])
        let snap = await fetchPlanSnapshot(auth: AUTH, doFetch: fetch, now: 1000)
        XCTAssertTrue(snap.available)
        XCTAssertEqual(snap.planName, "GLM Coding Pro")
        XCTAssertEqual(snap.level, "pro")
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.lastSuccessAt, 1000)
        XCTAssertNil(snap.error)
    }

    func testQuotaOnlySuccessStillAvailableWithSubscriptionError() async {
        let fetch = fakeFetch([
            "subscription/list": .error(TestError("boom")),
            "quota/limit": .json(QUOTA_OK),
        ])
        let snap = await fetchPlanSnapshot(auth: AUTH, doFetch: fetch, now: 1000)
        XCTAssertTrue(snap.available)
        XCTAssertEqual(snap.windows.count, 2)
        XCTAssertEqual(snap.error, "boom")
    }

    func testDualUnauthorizedMapsToHttp401() async {
        let e401 = HTTPStatusError(status: 401, message: "HTTP 401")
        let fetch = fakeFetch([
            "subscription/list": .error(e401),
            "quota/limit": .error(e401),
        ])
        let snap = await fetchPlanSnapshot(auth: AUTH, doFetch: fetch, now: 1000)
        XCTAssertFalse(snap.available)
        XCTAssertEqual(snap.unavailableReason, "http_401")
    }

    func testHttpErrorMapsToHttpErrorReason() async {
        let e500 = HTTPStatusError(status: 500, message: "HTTP 500")
        let fetch = fakeFetch([
            "subscription/list": .error(e500),
            "quota/limit": .error(e500),
        ])
        let snap = await fetchPlanSnapshot(auth: AUTH, doFetch: fetch, now: 1000)
        XCTAssertEqual(snap.unavailableReason, "http_error")
    }

    func testBusinessErrorCodeSurfacesMessage() async {
        let bad = jsonDict(["code": 3001, "msg": "parameter error"])
        let fetch = fakeFetch([
            "subscription/list": .json(bad),
            "quota/limit": .json(bad),
        ])
        let snap = await fetchPlanSnapshot(auth: AUTH, doFetch: fetch, now: 1000)
        XCTAssertFalse(snap.available)
        XCTAssertEqual(snap.error, "parameter error")
    }

    func testNoPlanDataYieldsNoPlanReason() async {
        let fetch = fakeFetch([
            "subscription/list": .json(jsonDict(["code": 200, "data": []])),
            "quota/limit": .json(jsonDict(["code": 200, "data": [:]])),
        ])
        let snap = await fetchPlanSnapshot(auth: AUTH, doFetch: fetch, now: 1000)
        XCTAssertFalse(snap.available)
        XCTAssertEqual(snap.unavailableReason, "no_plan")
    }
}
