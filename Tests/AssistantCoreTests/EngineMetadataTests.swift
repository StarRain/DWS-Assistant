import XCTest
@testable import AssistantCore

final class EngineMetadataTests: XCTestCase {
    func testEffectiveValuesResolveDefaultsOverridesAndAliases() {
        var settings = AgentSettings()
        var metadata = EngineMetadata.codex(models: [["model": "actual-model", "isDefault": true, "defaultReasoningEffort": "medium"]], config: [:])
        XCTAssertEqual(metadata.effectiveDefaults(for: settings), EngineDefaults(model: "actual-model", effort: "medium"))
        metadata.configuredEffort = "max"
        XCTAssertEqual(metadata.effectiveDefaults(for: settings).effort, "max")
        settings.model = "custom-model"; settings.reasoningEffort = .low
        XCTAssertEqual(metadata.effectiveDefaults(for: settings), EngineDefaults(model: "custom-model", effort: "low"))
        settings = AgentSettings(); settings.engine = .claude; settings.model = "sonnet"
        let claude = EngineMetadata.claude(models: [["value": "sonnet", "resolvedModel": "sonnet-resolved"]], defaults: EngineDefaults(effort: "high"))
        XCTAssertEqual(claude.effectiveDefaults(for: settings), EngineDefaults(model: "sonnet-resolved", effort: "high"))
        settings = AgentSettings(); settings.engine = .gemini
        XCTAssertEqual(EngineMetadata().effectiveDefaults(for: settings), EngineDefaults())
    }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-engine-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testCatalogUsesPerModelCapabilitiesAndConfiguredDefaults() {
        let metadata = EngineMetadata.codex(models: [
            ["model": "deep", "displayName": "Deep", "isDefault": true, "supportedReasoningEfforts": [["reasoningEffort": "low"], ["reasoningEffort": "max"]], "defaultReasoningEffort": "low"],
            ["model": "light", "supportedReasoningEfforts": [["reasoningEffort": "medium"]]],
            ["model": "hidden", "hidden": true]
        ], config: ["model": "deep", "model_reasoning_effort": "max"])
        XCTAssertEqual(metadata.defaultModel, "deep")
        XCTAssertEqual(metadata.configuredEffort, "max")
        XCTAssertEqual(metadata.option(for: "")?.efforts, [.low, .max])
        XCTAssertEqual(metadata.option(for: "light")?.efforts, [.medium])
        XCTAssertNil(metadata.option(for: "custom-model"))
        XCTAssertEqual(metadata.models.count, 2)
        let claude = EngineMetadata.claude(models: [["value": "default", "resolvedModel": "opus-test", "supportedEffortLevels": ["low", "high"]], ["value": "haiku", "resolvedModel": "haiku-test"]], defaults: EngineDefaults(effort: "high"))
        XCTAssertEqual(claude.defaultModel, "opus-test")
        XCTAssertEqual(claude.option(for: "")?.efforts, [.low, .high])
        XCTAssertEqual(claude.option(for: "haiku")?.efforts, [])
    }
    func testMetadataOnlyInitializesAndReadsWithoutInference() async throws {
        let dir = try temporaryDirectory(), executable = dir.appendingPathComponent("codex-fixture")
        let log = dir.appendingPathComponent("calls")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$PWD/arguments"
        printf '%s' "$CODEX_SQLITE_HOME" > "$PWD/sqlite-home"
        while IFS= read -r line; do
          printf '%s\n' "$line" >> "$PWD/calls"
          case "$line" in
            *'"method":"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
            *'"method":"config/read"'*) printf '%s\n' '{"id":2,"result":{"config":{"model":"test-model","model_reasoning_effort":"max"}}}' ;;
            *'"method":"model/list"'*) printf '%s\n' '{"id":3,"result":{"data":[{"model":"test-model","displayName":"Test","isDefault":true,"supportedReasoningEfforts":[{"reasoningEffort":"low"},{"reasoningEffort":"max"}]}]}}' ;;
          esac
        done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = AssistantConfig(); config.executablePaths["codex"] = executable.path
        let cache = dir.appendingPathComponent("cache \"中文\" \\name")
        let metadata = try await EngineMetadataReader.read(engine: .codex, workdir: dir.path, config: config, cacheDirectory: cache)
        XCTAssertEqual(metadata.defaultModel, "test-model"); XCTAssertEqual(metadata.configuredEffort, "max")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(calls.compactMap { $0["method"] as? String }, ["initialize", "initialized", "config/read", "model/list"])
        let arguments = try String(contentsOf: dir.appendingPathComponent("arguments"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(arguments.count, 3)
        XCTAssertEqual(arguments.first, "-c"); XCTAssertEqual(arguments.last, "app-server")
        XCTAssertTrue(arguments[1].hasPrefix("log_dir=\"/"), "The TOML override must retain an absolute path")
        XCTAssertFalse(arguments[1].contains(#"\/"#), "TOML does not accept JSON's escaped forward slashes")
        let quotedPath = Data(arguments[1].dropFirst("log_dir=".count).utf8)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: quotedPath), cache.appendingPathComponent("codex/logs").path)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sqlite-home"), encoding: .utf8), cache.appendingPathComponent("codex").path)
    }
    func testClaudeMetadataControlResponse() async throws {
        let dir = try temporaryDirectory(), executable = dir.appendingPathComponent("claude-fixture")
        let script = #"""
        #!/bin/sh
        IFS= read -r line
        printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"models","response":{"models":[{"value":"default","resolvedModel":"test-default","supportedEffortLevels":["medium","xhigh"]}]}}}'
        while IFS= read -r line; do exit 2; done
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        var config = AssistantConfig(); config.executablePaths["claude"] = executable.path
        let metadata = try await EngineMetadataReader.read(engine: .claude, workdir: dir.path, config: config, cacheDirectory: dir.appendingPathComponent("cache"))
        XCTAssertEqual(metadata.models.first?.resolvedModel, "test-default")
        XCTAssertEqual(metadata.models.first?.efforts, [.medium, .xhigh])
    }
    func testSettingsReadOnlyModelFieldsAndPrecedence() throws {
        let dir = try temporaryDirectory(), home = dir.appendingPathComponent("home"), work = dir.appendingPathComponent("work")
        for base in [home, work] { try FileManager.default.createDirectory(at: base.appendingPathComponent(".claude"), withIntermediateDirectories: true) }
        try #"{"model":"user-model","effortLevel":"low","env":{"TOKEN":"secret"}}"#.write(to: home.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try #"{"model":"project-model","effortLevel":"high"}"#.write(to: work.appendingPathComponent(".claude/settings.json"), atomically: true, encoding: .utf8)
        try #"{"effortLevel":"xhigh"}"#.write(to: work.appendingPathComponent(".claude/settings.local.json"), atomically: true, encoding: .utf8)
        let defaults = EngineDefaults.read(engine: .claude, workdir: work.path, home: home, environment: [:])
        XCTAssertEqual(defaults, EngineDefaults(model: "project-model", effort: "xhigh"))
        let env = EngineDefaults.read(engine: .claude, workdir: work.path, home: home, environment: ["ANTHROPIC_MODEL": "env-model"])
        XCTAssertEqual(env.model, "env-model")
    }
    func testAdditionalDirectoriesPersistWithoutSplittingCodexSession() throws {
        let dir = try temporaryDirectory(), extra = dir.appendingPathComponent("notes \"中文\"")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        var settings = AgentSettings(); settings.workdir = dir.path
        let empty = try JSONEncoder().encode(settings)
        XCTAssertFalse(String(decoding: empty, as: UTF8.self).contains("additionalDirectories"))
        XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: empty).additionalDirectories, [])
        let original = try Commands.officialAgent(settings, prompt: "test", route: "r", bridgePath: "/bin/echo", stateDirectory: dir.path, config: AssistantConfig())
        settings.additionalDirectories = [extra.path]
        XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings)), settings)
        let changed = try Commands.officialAgent(settings, prompt: "test", route: "r", bridgePath: "/bin/echo", stateDirectory: dir.path, config: AssistantConfig())
        let a = try JSONSerialization.jsonObject(with: Data(original.stdin!.utf8)) as! [String: Any]
        let b = try JSONSerialization.jsonObject(with: Data(changed.stdin!.utf8)) as! [String: Any]
        XCTAssertEqual(a["scope_id"] as? String, b["scope_id"] as? String)
        XCTAssertEqual(b["additional_directories"] as? [String], [extra.path])
        settings.engine = .gemini
        var config = AssistantConfig(); config.executablePaths["gemini"] = "/bin/echo"
        let command = try Commands.geminiCLI(settings, prompt: "test", config: config)
        XCTAssertEqual(Array(command.arguments.suffix(2)), ["--include-directories", extra.path])
        settings.additionalDirectories.append("relative/path")
        XCTAssertThrowsError(try Validation.agent(settings))
    }
    func testContactSearchKeepsOpenIDsAndDeduplicatesNestedResults() throws {
        let raw = #"{"data":{"result":{"users":[{"userId":"staff-only","name":"不能用员工 ID 监听"},{"openDingTalkId":"open-one","name":"联系人一"},{"open_dingtalk_id":"open-two","nick":"联系人二"},{"openDingTalkId":"open-one","name":"重复"}]}}}"#
        let result = try JSONOutput.contacts(CommandResult(status: 0, stdout: raw, stderr: ""))
        XCTAssertEqual(result.items.map(\.id), ["open-one", "open-two"])
        XCTAssertEqual(result.items.map(\.name), ["联系人一", "联系人二"])
        XCTAssertNil(result.nextCursor)
        XCTAssertThrowsError(try JSONOutput.contacts(CommandResult(status: 1, stdout: raw, stderr: "no permission")))
    }
}
