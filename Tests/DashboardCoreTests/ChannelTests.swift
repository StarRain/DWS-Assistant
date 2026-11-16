import XCTest
@testable import DashboardCore

final class ChannelTests: XCTestCase {
    private func payload(_ settings: AgentSettings) throws -> [String: Any] {
        let command = try Commands.officialAgent(settings, prompt: "hello", route: "corp:user|group|chat", bridgePath: "/bin/echo", stateDirectory: "/tmp/channel-tests", config: DashboardConfig())
        XCTAssertTrue(command.arguments.isEmpty, "Only the official bridge interprets the launch command")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(command.stdin).utf8)) as? [String: Any])
    }

    func testChannelsMapToOfficialNamesAndCustomIsNotAnInstalledCLI() {
        XCTAssertEqual(Set(Engine.allCases.map(\.channel)), Set(["codex", "claudecode", "qoder", "qoderwork", "opencode", "workbuddy", "codebuddy", "gemini", "pi", "custom"]))
        XCTAssertFalse(Engine.installedCLIEngines.contains(.custom))
        XCTAssertEqual(Engine.qoderwork.executable, "qodercli")
        XCTAssertEqual(Engine.workbuddy.executable, "codebuddy")
        XCTAssertEqual(Engine.executableNames.count, Set(Engine.executableNames).count)
    }

    func testCustomCommandPersistsAndReachesOfficialAdapterUnmodified() throws {
        let old = Data(#"{"engine":"claude","model":"","authorizedDirectories":[],"permission":"restricted","timeout":120}"#.utf8)
        var settings = try JSONDecoder().decode(AgentSettings.self, from: old)
        XCTAssertEqual(settings.agentCommand, "")
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("agentCommand"))
        settings.engine = .custom; settings.workdir = "/tmp"
        settings.agentCommand = #"python3 /tmp/agent.py --model local --literal '$(echo text)'"#
        XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings)), settings)
        let request = try payload(settings)
        XCTAssertEqual(request["channel"] as? String, "custom")
        XCTAssertEqual(request["agent_command"] as? String, settings.agentCommand)
        settings.agentCommand += " --other"
        XCTAssertNotEqual(try payload(settings)["scope_id"] as? String, request["scope_id"] as? String)
        settings.engine = .claude
        let withUnusedCommand = try payload(settings)
        settings.agentCommand = ""
        XCTAssertNil(withUnusedCommand["agent_command"])
        XCTAssertEqual(try payload(settings)["scope_id"] as? String, withUnusedCommand["scope_id"] as? String)
    }

    func testCustomRequiresCommandAndUnsupportedDirectorySettingsAreRejected() throws {
        var settings = AgentSettings(); settings.engine = .custom
        for empty in ["", "  \n "] {
            settings.agentCommand = empty
            XCTAssertThrowsError(try Validation.agent(settings))
        }
        settings.agentCommand = "python3 /tmp/agent.py"
        XCTAssertNoThrow(try Validation.agent(settings))
        settings.authorizedDirectories = ["/tmp", "/var"]
        for engine in [Engine.opencode, .pi, .workbuddy, .codebuddy, .custom] {
            settings.engine = engine
            XCTAssertThrowsError(try Validation.agent(settings), "Do not silently ignore extra directories")
            settings.authorizedDirectories = ["/tmp"]
            XCTAssertNoThrow(try Validation.agent(settings))
            settings.authorizedDirectories = ["/tmp", "/var"]
        }
    }

    func testNewChannelsDoNotReadGeminiDefaultsOrInventMetadata() async throws {
        for engine in [Engine.qoderwork, .opencode, .workbuddy, .codebuddy, .pi, .custom] {
            XCTAssertEqual(EngineDefaults.read(engine: engine, workdir: "", environment: ["GEMINI_MODEL": "wrong-model"]), EngineDefaults())
            let metadata = try await EngineMetadataReader.read(engine: engine, workdir: "", config: DashboardConfig(), cacheDirectory: URL(fileURLWithPath: "/tmp/unused-metadata"))
            XCTAssertTrue(metadata.models.isEmpty)
            XCTAssertEqual(metadata.defaultModel, "")
            XCTAssertFalse(metadata.detail.contains("Gemini"))
            var settings = AgentSettings(); settings.engine = engine; settings.workdir = "/tmp"; settings.agentCommand = "/bin/echo"
            XCTAssertEqual(try payload(settings)["channel"] as? String, engine.channel)
        }
    }
}
