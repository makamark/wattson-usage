// Support/Process.swift — 子进程运行工具（zed 钥匙串 / kiro sqlite3 / scutil 等只读探测）。
import Foundation

/// TS RunLike 的对应物：可注入（测试传 fake，生产 runProcess）
public typealias RunLike = @Sendable (String, [String]) async throws -> (stdout: String, stderr: String)

/// 裸命令名按常见 PATH 目录解析（execFile 的 PATH 语义；sqlite3/security/scutil 等）
public func resolveExecutable(_ file: String) -> String {
    if file.contains("/") { return file }
    for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"] {
        let p = dir + "/" + file
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return file
}

/// 运行外部命令并捕获 stdout/stderr；非零退出 / 启动失败抛错。5 秒超时。
public func runProcess(_ file: String, _ args: [String]) async throws -> (stdout: String, stderr: String) {
    enum RunOutcome: Sendable {
        case done(stdout: String, stderr: String)
        case timedOut
        case failed(String)
    }
    let outcome = try await withThrowingTaskGroup(of: RunOutcome.self) { group -> RunOutcome in
        group.addTask {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: resolveExecutable(file))
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            do {
                try p.run()
            } catch {
                return .failed("无法启动 \(file): \(error.localizedDescription)")
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else {
                return .failed("\(file) 退出码 \(p.terminationStatus)")
            }
            return .done(stdout: String(data: outData, encoding: .utf8) ?? "",
                         stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        group.addTask {
            // 超时哨兵：被取消时吞掉 CancellationError，正常返回 timedOut，
            // 避免组收尾把取消错误误当运行结果抛出
            do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch {}
            return .timedOut
        }
        let first = try await group.next()!
        group.cancelAll()
        _ = try? await group.next()
        return first
    }
    switch outcome {
    case .done(let stdout, let stderr):
        return (stdout: stdout, stderr: stderr)
    case .failed(let message):
        throw HTTPStatusError(status: 0, message: message)
    case .timedOut:
        throw HTTPStatusError(status: 0, message: "\(file) 执行超时")
    }
}

public func currentPlatform() -> String {
    #if os(macOS)
    return "darwin"
    #elseif os(Linux)
    return "linux"
    #else
    return "unknown"
    #endif
}
