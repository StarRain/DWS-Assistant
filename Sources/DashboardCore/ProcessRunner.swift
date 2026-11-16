import Foundation
import Darwin

public struct CommandSpec {
    public var executable: String
    public var arguments: [String]
    public var stdin: String?
    public var directory: String?
    public var environment: [String: String]?
    public var timeout: TimeInterval
    public var streaming: Bool
    public init(executable: String, arguments: [String], stdin: String? = nil, directory: String? = nil, environment: [String: String]? = nil, timeout: TimeInterval = 45, streaming: Bool = false) {
        self.executable = executable; self.arguments = arguments; self.stdin = stdin
        self.directory = directory; self.environment = environment; self.timeout = timeout; self.streaming = streaming
    }
}

public struct CommandResult {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public func checked() throws -> CommandResult {
        guard status == 0 else { throw DashboardError.command(Redaction.clean(stderr.isEmpty ? stdout : stderr)) }
        return self
    }
}

public enum Executables {
    public static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "\(home)/.local/bin", "/usr/local/bin", "\(home)/.qoder/entry", "/usr/bin", "/bin"]
    }
    public static func resolve(_ name: String, overrides: [String: String] = [:]) throws -> String {
        if let custom = overrides[name], !custom.isEmpty {
            guard custom.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: custom) else { throw DashboardError.invalid("\(name) 的自定义路径不可执行") }
            return custom
        }
        let inherited = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for directory in searchDirectories + inherited {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw DashboardError.invalid("未找到 \(name)，请先安装对应工具后重新打开面板")
    }
    public static func environment(overrides: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Do not inherit DWS override hooks/credentials from the host terminal.
        for key in Array(env.keys) where key.hasPrefix("DWS_") { env.removeValue(forKey: key) }
        let custom = overrides.values.filter { !$0.isEmpty }.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }
        env["PATH"] = (custom + searchDirectories + [env["PATH"] ?? ""]).joined(separator: ":")
        env["NO_COLOR"] = "1"; env["TERM"] = "dumb"; env["DWS_LANG"] = "zh"
        env["DWS_CONNECT_NO_INSTALL"] = "1"
        return env
    }
}

/// Uses argv, never a shell. Drains both pipes concurrently and bounds memory.
public final class ProcessJob: @unchecked Sendable {
    private let spec: CommandSpec
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSRecursiveLock()
    private var stopped: Error?
    private var started = false
    private var completed = false
    private var outputData = Data()
    private var errorData = Data()
    private var timer: DispatchSourceTimer?
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return started && process.isRunning }

    public init(_ spec: CommandSpec) { self.spec = spec }
    public func sendInput(_ text: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard started, !completed, stopped == nil, process.isRunning else { throw DashboardError.command("引擎元数据连接已关闭") }
        try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
    }
    public func cancel(_ reason: Error = DashboardError.cancelled) {
        lock.lock(); defer { lock.unlock() }
        if stopped == nil { stopped = reason }
        if started && process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    public func start(onLine: @escaping (String, Bool) -> Void = { _, _ in }, completion: @escaping (Result<CommandResult, Error>) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !started && !completed else { return }
        if let stopped { completed = true; completion(.failure(stopped)); return }
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment ?? Executables.environment()
        if let directory = spec.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let readers = DispatchGroup()
        readers.enter(); readers.enter()
        process.terminationHandler = { [self] p in
            readers.notify(queue: .global(qos: .utility)) { [self] in
                lock.lock()
                timer?.cancel(); timer = nil
                completed = true
                let failure = stopped
                let result = CommandResult(status: p.terminationStatus, stdout: String(decoding: outputData, as: UTF8.self), stderr: String(decoding: errorData, as: UTF8.self))
                lock.unlock()
                completion(failure.map { .failure($0) } ?? .success(result))
            }
        }
        do { try process.run(); started = true }
        catch { completed = true; completion(.failure(error)); return }
        try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        drain(output.fileHandleForReading, isError: false, group: readers, onLine: onLine)
        drain(errors.fileHandleForReading, isError: true, group: readers, onLine: onLine)
        if spec.stdin != nil || !spec.streaming {
            DispatchQueue.global(qos: .utility).async { [self] in
                do {
                    if let text = spec.stdin { try input.fileHandleForWriting.write(contentsOf: Data(text.utf8)) }
                    try input.fileHandleForWriting.close()
                } catch { /* The child may intentionally close stdin early. Its exit result is authoritative. */ }
            }
        }
        if spec.timeout > 0 {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + spec.timeout)
            timer.setEventHandler { [weak self] in self?.cancel(DashboardError.timedOut) }
            self.timer = timer; timer.resume()
        }
    }

    private func drain(_ handle: FileHandle, isError: Bool, group: DispatchGroup, onLine: @escaping (String, Bool) -> Void) {
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { try? handle.close(); group.leave() }
            var pending = Data()
            do {
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    // FileHandle.read(upToCount:) may wait for a full buffer on pipes.
                    // POSIX read emits each available chunk, so ready/event lines are live.
                    let countRead = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
                    if countRead == 0 { break }
                    if countRead < 0 {
                        if errno == EINTR { continue }
                        throw DashboardError.command("读取 CLI 输出失败（\(errno)）")
                    }
                    let data = Data(buffer.prefix(countRead))
                    lock.lock()
                    let limit = isError ? 65_536 : 2_097_152
                    if isError { errorData.append(data) } else { outputData.append(data) }
                    let count = isError ? errorData.count : outputData.count
                    if count > limit {
                        if spec.streaming {
                            if isError { errorData = errorData.suffix(32_768) } else { outputData = Data() }
                        } else {
                            if isError { errorData = errorData.prefix(limit) } else { outputData = outputData.prefix(limit) }
                            cancel(DashboardError.outputLimit)
                        }
                    }
                    lock.unlock()
                    pending.append(data)
                    while let end = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<end], as: UTF8.self)
                        pending.removeSubrange(...end)
                        onLine(line, isError)
                    }
                    if pending.count > 262_144 { cancel(DashboardError.outputLimit); pending.removeAll() }
                }
                if !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self), isError) }
            } catch { cancel(error) }
        }
    }

    public func value(onLine: @escaping (String, Bool) -> Void = { _, _ in }) async throws -> CommandResult {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(onLine: onLine) { continuation.resume(with: $0) }
            }
        } onCancel: { self.cancel() }
    }
}

public enum ProcessRunner {
    public static func run(_ spec: CommandSpec) async throws -> CommandResult { try await ProcessJob(spec).value() }
}
