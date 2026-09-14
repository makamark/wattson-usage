// Support/Files.swift — 文件小工具：读文本（不存在/损坏返回 nil 口径与 TS try/catch 一致）。
import Foundation

public func readTextFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: data, encoding: .utf8)
}

public func readDataFile(_ path: String) -> Data? {
    FileManager.default.contents(atPath: path)
}

/// 按字节逐行迭代（不物化整文件 String；大 JSONL 扫描的热路径）
public func forEachLine(_ data: Data, _ body: (Data) throws -> Void) rethrows {
    var start = data.startIndex
    var i = start
    while i < data.endIndex {
        if data[i] == 0x0A {
            if i > start { try body(data.subdata(in: start..<i)) }
            start = data.index(after: i)
        }
        i = data.index(after: i)
    }
    if start < data.endIndex { try body(data.subdata(in: start..<data.endIndex)) }
}

public func writeTextFile(_ path: String, _ content: String) -> Bool {
    do {
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        return true
    } catch { return false }
}

public func parseJSONFile(_ path: String) -> JSON? {
    guard let raw = readTextFile(path), let json = try? JSON.parse(raw) else { return nil }
    return json
}

public func expandHome(_ p: String, home: String? = nil) -> String {
    let h = home ?? NSHomeDirectory()
    if p == "~" { return h }
    if p.hasPrefix("~/") { return (h as NSString).appendingPathComponent(String(p.dropFirst(2))) }
    return p
}

public func listDirectory(_ path: String) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
}

public func fileExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path)
}

public func homePath() -> String { NSHomeDirectory() }

public func shortHostname() -> String {
    let name = ProcessInfo.processInfo.hostName
    if let dot = name.firstIndex(of: ".") { return String(name[..<dot]) }
    return name
}
