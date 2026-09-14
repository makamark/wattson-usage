// ConfigTests.swift — server/tests/config.test.ts 的移植。
import XCTest
@testable import WattsonCore

final class ConfigTests: XCTestCase {
    private var file = ""

    override func setUp() {
        super.setUp()
        file = (makeTempDir(prefix: "cfg-") as NSString).appendingPathComponent("agg.config.json")
    }

    func testReadsServerSectionFromConfigFile() throws {
        writeFixture(file, #"{"server": {"port": 9000, "refreshMinutes": 15}, "devices": []}"#)
        let cfg = try loadFileConfig(file)
        XCTAssertEqual(cfg, FileConfig(port: 9000, refreshMinutes: 15))
    }

    func testReadsWebDistThrough() throws {
        writeFixture(file, #"{"server": {"port": 9000, "webDist": "/x/web/dist"}}"#)
        let cfg = try loadFileConfig(file)
        XCTAssertEqual(cfg, FileConfig(port: 9000, webDist: "/x/web/dist"))
    }

    func testReturnsDefaultsWhenFileMissing() throws {
        let cfg = try loadFileConfig(file)
        XCTAssertEqual(cfg, FileConfig())
    }

    func testRejectsCorruptJSONInsteadOfSilentlyDefaulting() {
        writeFixture(file, "{bad")
        XCTAssertThrowsError(try loadFileConfig(file)) { err in
            XCTAssertTrue(err is ConfigError)
        }
    }

    func testRejectsNonObjectTopLevel() {
        writeFixture(file, "[1,2]")
        XCTAssertThrowsError(try loadFileConfig(file)) { err in
            XCTAssertTrue(err is ConfigError)
        }
    }

    func testRejectsOutOfRangePortAndNonIntegerRefreshMinutes() throws {
        writeFixture(file, #"{"server": {"port": 70000}}"#)
        XCTAssertThrowsError(try loadFileConfig(file)) { XCTAssertTrue($0 is ConfigError) }
        writeFixture(file, #"{"server": {"port": 9000, "refreshMinutes": 1.5}}"#)
        XCTAssertThrowsError(try loadFileConfig(file)) { XCTAssertTrue($0 is ConfigError) }
        writeFixture(file, #"{"server": {"port": "9000"}}"#)
        XCTAssertThrowsError(try loadFileConfig(file)) { XCTAssertTrue($0 is ConfigError) }
    }
}
