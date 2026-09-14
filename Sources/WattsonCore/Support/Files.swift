// Support/Files.swift — 文件小工具：读文本（不存在/损坏返回 nil 口径与 TS try/catch 一致）。
import Foundation

public func readTextFile(_ path: String) -> String? {
    guard let data = FileManager.default.contents(atPath: path) else { return nil }
    return String(data: data, encoding: .utf8)
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
