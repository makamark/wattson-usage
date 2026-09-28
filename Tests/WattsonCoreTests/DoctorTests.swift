// DoctorTests — doctor 健康检查：配置/多设备/数据目录/价目缓存/用量源 五项。
// 全部走临时目录 fixture，不触碰真实家目录。
import XCTest
@testable import WattsonCore

final class DoctorTests: XCTestCase {
    private func tmpDir() -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("wattson-doctor-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ path: String, _ content: String) {
        try! FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func check(_ report: DoctorReport, _ name: String) -> DoctorCheck {
        report.checks.first { $0.name == name }!
    }

    func testHealthyEnvironmentAllPass() {
        let home = tmpDir()
        let cfg = home + "/wattson/agg.config.json"
        write(cfg, #"{"server":{"port":9000}}"#)
        let pricing = home + "/wattson/cache/litellm-prices.json"
        write(pricing, "{}")
        try! FileManager.default.createDirectory(atPath: home + "/.claude", withIntermediateDirectories: true)

        let report = doctorChecks(configPath: cfg, dataDir: home + "/wattson",
                                  home: home, pricingPath: pricing, now: Date())
        XCTAssertTrue(report.allOk)
        XCTAssertTrue(check(report, "配置文件").ok)
        XCTAssertTrue(check(report, "配置文件").detail.contains("9000"))
        XCTAssertTrue(check(report, "本机用量源").detail.contains("claude"))
        XCTAssertTrue(check(report, "价目缓存").detail.contains("新鲜"))
    }

    func testCorruptConfigFails() {
        let home = tmpDir()
        let cfg = home + "/wattson/agg.config.json"
        write(cfg, "not json")
        let report = doctorChecks(configPath: cfg, dataDir: home + "/wattson",
                                  home: home, pricingPath: home + "/none.json", now: Date())
        XCTAssertFalse(check(report, "配置文件").ok)
        XCTAssertFalse(report.allOk)
    }

    func testMissingEverythingIsInformationalExceptSources() {
        let home = tmpDir()
        let report = doctorChecks(configPath: home + "/wattson/agg.config.json",
                                  dataDir: home + "/wattson", home: home, now: Date())
        // 配置缺省 / 价目缺省 / 多设备空 都是正常状态，不算故障
        XCTAssertTrue(check(report, "配置文件").ok)
        XCTAssertTrue(check(report, "价目缓存").ok)
        XCTAssertTrue(check(report, "多设备根").ok)
        XCTAssertTrue(check(report, "数据目录").ok)  // doctor 顺带创建
        // 一个用量源都没有才判未通过
        XCTAssertFalse(check(report, "本机用量源").ok)
        XCTAssertFalse(report.allOk)
    }

    func testDevicesFileHonoredViaEnv() {
        let home = tmpDir()
        let dev = home + "/devices.json"
        write(dev, #"[{"host":"workstation","zcodeDb":"~/wattson/mirror/workstation/zcode/db.sqlite"}]"#)
        let report = doctorChecks(env: ["WATTSON_DEVICES_FILE": dev],
                                  dataDir: home + "/wattson", home: home, now: Date())
        XCTAssertTrue(check(report, "多设备根").ok)
        XCTAssertTrue(check(report, "多设备根").detail.contains("workstation"))
    }

    func testStalePricingCacheIsInformational() throws {
        let home = tmpDir()
        let pricing = home + "/wattson/cache/litellm-prices.json"
        write(pricing, "{}")
        let stale = Date().addingTimeInterval(-48 * 3600)
        try FileManager.default.setAttributes(
            [.modificationDate: stale], ofItemAtPath: pricing)
        let report = doctorChecks(home: home, pricingPath: pricing, now: Date())
        let pricingCheck = check(report, "价目缓存")
        XCTAssertTrue(pricingCheck.ok)
        XCTAssertTrue(pricingCheck.detail.contains("已过期"))
    }

    func testRenderContainsMarksAndVersion() {
        let report = doctorChecks(home: tmpDir())
        let text = renderDoctorReport(report, version: "9.9.9")
        XCTAssertTrue(text.contains("Wattson doctor（v9.9.9）"))
        XCTAssertTrue(text.contains("✓") || text.contains("✗"))
    }
}
