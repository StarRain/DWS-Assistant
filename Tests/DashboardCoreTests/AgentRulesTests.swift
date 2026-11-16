import XCTest
@testable import DashboardCore

final class AgentRulesTests: XCTestCase {
    private func workspace() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-rules-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func payload(_ settings: AgentSettings, route: String = "corp:user|group|a", directory: URL) throws -> [String: Any] {
        let command = try Commands.officialAgent(settings, prompt: "本轮聊天", route: route, bridgePath: "/bin/echo", stateDirectory: directory.path, config: DashboardConfig())
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(command.stdin).utf8)) as? [String: Any])
    }

    func testLegacySettingsAndRulePersistenceAcrossConversations() throws {
        let old = Data(#"{"engine":"codex","model":"","authorizedDirectories":[],"permission":"restricted","timeout":120}"#.utf8)
        var settings = try JSONDecoder().decode(AgentSettings.self, from: old)
        XCTAssertTrue(settings.rules.isEmpty)
        let unchanged = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        XCTAssertNil(unchanged["rules"], "Existing settings must retain their session fingerprint")
        settings.rules = [AgentRule(name: "项目打包", content: "进入已授权的项目目录，执行 scripts/build.sh。"),
                          AgentRule(name: "回复格式", content: "先写结论再列步骤。", enabled: false)]
        var group = Conversation(); group.stableID = "group"; group.profile = "corp:user"; group.agent = settings
        var contact = Conversation(); contact.kind = .contact; contact.stableID = "contact"; contact.profile = "corp:user"
        var config = DashboardConfig(); config.conversations = [group, contact]
        let decoded = try JSONDecoder().decode(DashboardConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
        XCTAssertFalse(decoded.conversations[0].agent.rules[1].enabled)
        XCTAssertTrue(decoded.conversations[1].agent.rules.isEmpty)
        XCTAssertNoThrow(try Validation.configuration(decoded))
    }

    func testOnlyEnabledRulesReachEveryEngineWithoutChangingAccess() throws {
        let directory = try workspace()
        let content = "当我说“打包”时执行 scripts/build.sh；路径含空格、\"引号\"、$(printf unexpected)。\n返回结果。"
        for engine in Engine.allCases {
            var settings = AgentSettings(); settings.engine = engine
            settings.authorizedDirectories = [directory.path]
            settings.rules = [AgentRule(name: "项目打包", content: content), AgentRule(name: "不启用", content: "disabled-sentinel", enabled: false)]
            let encoded = try AgentRules.encodedInstructions(settings.rules)
            let decoded = try JSONDecoder().decode([AgentRules.Instruction].self, from: Data(encoded.utf8))
            XCTAssertEqual(decoded.count, 1); XCTAssertEqual(decoded[0].content, content)
            if engine == .gemini {
                var config = DashboardConfig(); config.executablePaths["gemini"] = "/bin/echo"
                let command = try Commands.officialAgent(settings, prompt: "本轮聊天", route: "a", bridgePath: "/bin/echo", stateDirectory: directory.path, config: config)
                XCTAssertTrue(command.stdin?.contains(encoded) == true)
                XCTAssertFalse(command.stdin?.contains("disabled-sentinel") == true)
                XCTAssertTrue(command.arguments.contains("plan")); XCTAssertFalse(command.arguments.contains("yolo"))
                XCTAssertFalse(command.arguments.joined().contains("build.sh"), "Rules must never become host command arguments")
                XCTAssertEqual(command.directory, directory.path)
            } else {
                let request = try payload(settings, directory: directory)
                XCTAssertEqual(request["authorized_directories"] as? [String], [directory.path])
                XCTAssertEqual(request["full_permission"] as? Bool, false)
                if engine == .codex {
                    XCTAssertEqual(request["custom_rules"] as? String, encoded)
                    XCTAssertEqual(request["text"] as? String, "本轮聊天")
                } else {
                    XCTAssertNil(request["custom_rules"])
                    XCTAssertTrue((request["text"] as? String)?.contains(encoded) == true)
                    XCTAssertFalse((request["text"] as? String)?.contains("disabled-sentinel") == true)
                }
            }
        }
    }

    func testCodexUpdatesEffectiveRulesWithoutSplittingConversation() throws {
        let directory = try workspace()
        var settings = AgentSettings()
        let original = try payload(settings, directory: directory)["scope_id"] as? String
        settings.rules = [AgentRule(name: "暂存", content: "关闭的规则", enabled: false)]
        XCTAssertEqual(try payload(settings, directory: directory)["scope_id"] as? String, original)
        settings.rules[0].enabled = true
        let enabled = try payload(settings, directory: directory)["scope_id"] as? String
        XCTAssertEqual(enabled, original)
        settings.rules[0].id = UUID()
        XCTAssertEqual(try payload(settings, directory: directory)["scope_id"] as? String, enabled)
        settings.rules[0].content = "新内容"
        XCTAssertEqual(try payload(settings, directory: directory)["scope_id"] as? String, enabled)
        XCTAssertTrue((try payload(settings, directory: directory)["custom_rules"] as? String)?.contains("新内容") == true)
        XCTAssertNotEqual(try payload(settings, directory: directory)["scope_id"] as? String,
                          try payload(settings, route: "corp:user|contact|b", directory: directory)["scope_id"] as? String)
        settings.rules[0].enabled = false
        XCTAssertEqual(try payload(settings, directory: directory)["scope_id"] as? String, original)
        XCTAssertNil(try payload(settings, directory: directory)["custom_rules"])
    }

    func testBlankOversizedAndDuplicateRulesAreRejectedWithoutTruncation() throws {
        XCTAssertNoThrow(try AgentRules.validate([]))
        for rule in [AgentRule(), AgentRule(name: "有效名称", content: "  \n"),
                     AgentRule(name: String(repeating: "名", count: 61), content: "内容"),
                     AgentRule(name: "规则", content: String(repeating: "文", count: 2_001)),
                     AgentRule(name: "规则\n名称", content: "内容")] {
            var settings = AgentSettings(); settings.rules = [rule]
            XCTAssertThrowsError(try Validation.agent(settings))
        }
        let rule = AgentRule(name: "规则", content: "内容")
        XCTAssertThrowsError(try AgentRules.validate([rule, rule]))
    }

    func testRuleCountAndCombinedContentHaveNoEditingLimit() throws {
        var settings = AgentSettings()
        settings.rules = (0..<150).map { AgentRule(name: "规则\($0)", content: String(repeating: "文", count: 200)) }
        XCTAssertNoThrow(try Validation.agent(settings))
        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AgentSettings.self, from: data)
        XCTAssertEqual(restored.rules, settings.rules)
        let instructions = try AgentRules.encodedInstructions(restored.rules)
        XCTAssertGreaterThan(instructions.utf8.count, 48 * 1024)
        XCTAssertEqual(try JSONDecoder().decode([AgentRules.Instruction].self, from: Data(instructions.utf8)).count, 150)
        let directory = try workspace()
        XCTAssertEqual(try payload(restored, directory: directory)["custom_rules"] as? String, instructions)
        settings.rules = settings.rules.map { var rule = $0; rule.enabled = false; return rule }
        XCTAssertEqual(try AgentRules.encodedInstructions(settings.rules), "")
    }
}
