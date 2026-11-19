import Foundation

public struct EngineModelOption: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var resolvedModel: String
    public var efforts: [ReasoningEffort]
    public var defaultEffort: String
    public var isDefault: Bool
}

public struct EngineMetadata: Equatable {
    public var models: [EngineModelOption] = []
    public var defaultModel = ""
    public var configuredEffort = ""
    public var detail = ""
    public init() {}
    public func option(for model: String) -> EngineModelOption? {
        let selected = model.isEmpty ? defaultModel : model
        return models.first { $0.id == selected || $0.resolvedModel == selected }
            ?? (selected.isEmpty ? models.first(where: \.isDefault) : nil)
    }
    public func effectiveDefaults(for settings: AgentSettings) -> EngineDefaults {
        let option = option(for: settings.model)
        let model = option?.resolvedModel.nonempty ?? settings.model.nonempty ?? defaultModel
        let effort = !settings.engine.supportsReasoning ? "" : settings.reasoningEffort != .inherit
            ? settings.reasoningEffort.rawValue
            : configuredEffort.nonempty ?? option?.defaultEffort ?? ""
        return EngineDefaults(model: model, effort: effort)
    }
    public static func codex(models: [[String: Any]], config: [String: Any]) -> EngineMetadata {
        var result = EngineMetadata()
        result.models = models.compactMap { row in
            let id = JSONOutput.string(row, "model", "id")
            guard !id.isEmpty, row["hidden"] as? Bool != true else { return nil }
            let efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { ReasoningEffort(rawValue: JSONOutput.string($0, "reasoningEffort")) }
            return EngineModelOption(id: id, name: JSONOutput.string(row, "displayName").nonempty ?? id, resolvedModel: id,
                                     efforts: efforts, defaultEffort: JSONOutput.string(row, "defaultReasoningEffort"), isDefault: row["isDefault"] as? Bool == true)
        }
        result.defaultModel = JSONOutput.string(config, "model").nonempty ?? result.models.first(where: \.isDefault)?.id ?? ""
        result.configuredEffort = JSONOutput.string(config, "model_reasoning_effort")
        result.detail = "已从 Codex 读取模型与强度"
        return result
    }
    public static func claude(models: [[String: Any]], defaults: EngineDefaults) -> EngineMetadata {
        var result = EngineMetadata()
        result.models = models.compactMap { row in
            let id = JSONOutput.string(row, "value")
            guard !id.isEmpty else { return nil }
            return EngineModelOption(id: id, name: JSONOutput.string(row, "displayName").nonempty ?? id,
                                     resolvedModel: JSONOutput.string(row, "resolvedModel"),
                                     efforts: (row["supportedEffortLevels"] as? [String] ?? []).compactMap(ReasoningEffort.init(rawValue:)),
                                     defaultEffort: "", isDefault: id == "default")
        }
        result.defaultModel = defaults.model.nonempty ?? result.models.first(where: \.isDefault)?.resolvedModel ?? ""
        result.configuredEffort = defaults.effort
        result.detail = "已从 Claude Code 读取模型与强度"
        return result
    }
}

/// Read only the model-related settings. Never copy credentials, hooks or other
/// user configuration into a conversation. The same defaults drive execution.
public struct EngineDefaults: Equatable {
    public var model = ""
    public var effort = ""
    public init(model: String = "", effort: String = "") { self.model = model; self.effort = effort }
    public static func read(engine: Engine, workdir: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            environment: [String: String] = ProcessInfo.processInfo.environment) -> EngineDefaults {
        guard [.claude, .qoder, .gemini].contains(engine) else { return EngineDefaults() }
        let folder = engine == .claude ? ".claude" : engine == .qoder ? ".qoder" : ".gemini"
        let user = environment[engine == .claude ? "CLAUDE_CONFIG_DIR" : engine == .qoder ? "QODER_CONFIG_DIR" : "GEMINI_CLI_HOME"]
        let base = user.map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(folder)
        var result = EngineDefaults()
        var files = [base.appendingPathComponent("settings.json")]
        if !workdir.isEmpty {
            let project = URL(fileURLWithPath: workdir).appendingPathComponent(folder)
            files.append(project.appendingPathComponent("settings.json"))
            if engine != .gemini { files.append(project.appendingPathComponent("settings.local.json")) }
        }
        for file in files {
            guard let data = try? Data(contentsOf: file), data.count < 2_097_152,
                  let settings = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
            if engine == .claude {
                if let model = settings["model"] as? String { result.model = model }
                if let effort = settings["effortLevel"] as? String { result.effort = effort }
            } else if let model = settings["model"] as? [String: Any] {
                if let name = model["name"] as? String { result.model = name }
                if let effort = model["reasoningEffort"] as? String { result.effort = effort }
            }
        }
        if engine == .claude {
            if let model = environment["ANTHROPIC_MODEL"], !model.isEmpty { result.model = model }
            if let effort = environment["CLAUDE_CODE_EFFORT_LEVEL"], !effort.isEmpty { result.effort = effort }
        } else if engine == .gemini, let model = environment["GEMINI_MODEL"], !model.isEmpty { result.model = model }
        return result
    }
}

public enum EngineMetadataReader {
    public static func read(engine: Engine, workdir: String, config: AssistantConfig, cacheDirectory: URL) async throws -> EngineMetadata {
        if ![.codex, .claude, .qoder, .gemini].contains(engine) {
            var result = EngineMetadata()
            result.detail = engine == .custom ? "启动命令按 DWS 官方 agent-cmd 执行" : "使用 DWS 官方适配器；模型留空沿用渠道默认值"
            return result
        }
        let workdir = try AssistantPaths.agentWorkdir(workdir, fallback: cacheDirectory.appendingPathComponent("workspace", isDirectory: true))
        let executable = try Executables.resolve(engine.executable, overrides: config.executablePaths)
        var environment = Executables.environment(overrides: config.executablePaths)
        let defaults = EngineDefaults.read(engine: engine, workdir: workdir, environment: environment)
        if engine == .codex {
            let cache = cacheDirectory.appendingPathComponent("codex", isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            environment["CODEX_SQLITE_HOME"] = cache.path
            // Codex's -c value is TOML, where JSON's optional \/ escape is
            // invalid and can turn an absolute log path into a relative one.
            let pathEncoder = JSONEncoder()
            pathEncoder.outputFormatting = .withoutEscapingSlashes
            let quotedLog = String(decoding: try pathEncoder.encode(cache.appendingPathComponent("logs").path), as: UTF8.self)
            let session = MetadataConnection(CommandSpec(executable: executable, arguments: ["-c", "log_dir=" + quotedLog, "app-server"], directory: workdir, environment: environment, timeout: 20, streaming: true))
            defer { session.close() }
            _ = try await session.query(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "dws_assistant_metadata", "version": "1.0.0"], "capabilities": [:]]], id: "1")
            try session.notify(["method": "initialized"])
            let configResult = try await session.query(["id": 2, "method": "config/read", "params": ["includeLayers": false, "cwd": workdir]], id: "2")
            var models: [[String: Any]] = [], cursor: String?, seen = Set<String>()
            for index in 3...12 {
                var params: [String: Any] = ["limit": 100]
                if let cursor { params["cursor"] = cursor }
                let result = try await session.query(["id": index, "method": "model/list", "params": params], id: String(index))
                models += result["data"] as? [[String: Any]] ?? []
                cursor = result["nextCursor"] as? String
                guard let cursor, !cursor.isEmpty, seen.insert(cursor).inserted else { break }
            }
            guard !models.isEmpty else { throw AssistantError.command("Codex 未返回模型列表") }
            return EngineMetadata.codex(models: models, config: configResult["config"] as? [String: Any] ?? [:])
        }
        if engine == .claude {
            let args = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--safe-mode", "--no-session-persistence", "--setting-sources", "project"]
            let session = MetadataConnection(CommandSpec(executable: executable, arguments: args, directory: workdir, environment: environment, timeout: 20, streaming: true))
            defer { session.close() }
            let result = try await session.query(["type": "control_request", "request_id": "models", "request": ["subtype": "initialize"]], id: "models")
            guard let models = result["models"] as? [[String: Any]], !models.isEmpty else { throw AssistantError.command("当前 Claude Code 未返回模型列表") }
            return EngineMetadata.claude(models: models, defaults: defaults)
        }
        var result = EngineMetadata(); result.defaultModel = defaults.model; result.configuredEffort = defaults.effort
        if engine == .qoder {
            let response = try await ProcessRunner.run(CommandSpec(executable: executable, arguments: ["--list-models", "--output-format", "json"], directory: workdir, environment: environment, timeout: 15))
            _ = try response.checked()
            // Versions without structured output still use their own default;
            // never invent an available catalog from a static marketing list.
            if let raw = try? JSONSerialization.jsonObject(with: Data(response.stdout.utf8)) {
                let rows = raw as? [[String: Any]] ?? (raw as? [String: Any])?["models"] as? [[String: Any]] ?? []
                result.models = rows.compactMap { row in
                    let id = JSONOutput.string(row, "id", "name", "model")
                    guard !id.isEmpty else { return nil }
                    return EngineModelOption(id: id, name: JSONOutput.string(row, "displayName", "display_name").nonempty ?? id, resolvedModel: id,
                        efforts: (row["supportedEffortLevels"] as? [String] ?? []).compactMap(ReasoningEffort.init(rawValue:)), defaultEffort: "", isDefault: false)
                }
            }
            result.detail = result.models.isEmpty ? "此版本未提供可解析的模型列表，可填写模型名称" : "已从 Qoder 读取模型列表"
        } else { result.detail = "已读取 Gemini 本机模型配置；此引擎未提供模型列表查询" }
        return result
    }
}

/// Metadata-only JSON RPC/control exchange. No thread, user prompt or turn is
/// ever submitted. Cancellation closes the child and resolves all waiters.
private final class MetadataConnection: @unchecked Sendable {
    private let job: ProcessJob
    private let lock = NSRecursiveLock()
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var failure: Error?
    init(_ spec: CommandSpec) {
        job = ProcessJob(spec)
        job.start(onLine: { [weak self] line, isError in if !isError { self?.receive(line) } }, completion: { [weak self] result in
            switch result {
            case .failure(let error): self?.finish(error)
            case .success(let output): self?.finish(AssistantError.command(output.stderr.isEmpty ? "未能读取引擎模型列表" : Redaction.clean(String(output.stderr.suffix(500)))))
            }
        })
    }
    func notify(_ body: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        try job.sendInput(String(decoding: data, as: UTF8.self) + "\n")
    }
    func query(_ body: [String: Any], id: String) async throws -> [String: Any] {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                lock.lock(); defer { lock.unlock() }
                if let failure { continuation.resume(throwing: failure); return }
                pending[id] = continuation
                do { try notify(body) } catch { pending.removeValue(forKey: id)?.resume(throwing: error) }
            }
        } onCancel: { self.close() }
    }
    func close() { finish(AssistantError.cancelled); job.cancel() }
    private func finish(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        if failure == nil { failure = error }
        let callbacks = pending.values; pending = [:]
        for callback in callbacks { callback.resume(throwing: error) }
    }
    private func receive(_ line: String) {
        guard let row = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return }
        let control = row["type"] as? String == "control_response" ? row["response"] as? [String: Any] : nil
        let id = control.map { JSONOutput.string($0, "request_id") } ?? JSONOutput.string(row, "id")
        lock.lock(); defer { lock.unlock() }
        guard let callback = pending.removeValue(forKey: id) else { return }
        if let control {
            if control["subtype"] as? String == "error" { callback.resume(throwing: AssistantError.command(Redaction.clean(JSONOutput.string(control, "error")))) }
            else { callback.resume(returning: control["response"] as? [String: Any] ?? [:]) }
        } else if let error = row["error"] as? [String: Any] {
            callback.resume(throwing: AssistantError.command(Redaction.clean(JSONOutput.string(error, "message"))))
        } else { callback.resume(returning: row["result"] as? [String: Any] ?? [:]) }
    }
}
