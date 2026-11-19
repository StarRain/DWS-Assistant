import XCTest
@testable import AssistantCore

final class SessionBindingTests: XCTestCase {
    func payload(_ c: Conversation) throws -> [String: Any] {
        let spec = try Commands.officialAgent(c.agent, prompt: "本轮消息", route: c.routingKey, bridgePath: "/bin/echo", stateDirectory: "/tmp/dashboard-session-tests", config: AssistantConfig(), sessionTitle: c.defaultCodexSessionTitle)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(spec.stdin!.utf8)) as? [String: Any])
    }

    func testOneCodexBindingPerAccountAndConversationAcrossSettingsEdits() throws {
        var c = Conversation(); c.profile = "corp:user"; c.stableID = "group"; c.name = "项目群"; c.agent.workdir = "/tmp"
        let original = try payload(c)
        c.agent.model = "next-model"; c.agent.reasoningEffort = .low
        c.agent.timeout = 180; c.agent.permission = .full
        c.agent.authorizedDirectories = ["/tmp", "/private/tmp"]
        c.agent.rules = [AgentRule(name: "回复", content: "简洁回复")]
        c.agent.sessionTitle = "打包助手"
        c.replyFormat = .aiCard; c.cardInteractionTimeout = 60; c.showAITag = false
        let changed = try payload(c)
        XCTAssertEqual(original["scope_id"] as? String, changed["scope_id"] as? String)
        XCTAssertEqual(changed["scope_id"] as? String, CodexHistory.scope(route: c.routingKey))
        XCTAssertEqual(original["conversation_id"] as? String, changed["conversation_id"] as? String)
        XCTAssertEqual(changed["model"] as? String, "next-model")
        XCTAssertEqual(changed["reasoning_effort"] as? String, "low")
        XCTAssertEqual(changed["timeout_seconds"] as? Int, 180)
        XCTAssertEqual(changed["full_permission"] as? Bool, true)
        XCTAssertNil(changed["legacy_scope_id"])
        for edit in [0, 1, 2] {
            var other = c
            if edit == 0 { other.profile = "corp:other" }
            if edit == 1 { other.kind = .contact }
            if edit == 2 { other.stableID = "other-group" }
            XCTAssertNotEqual(try payload(other)["scope_id"] as? String, changed["scope_id"] as? String)
        }
    }

    func testCodexTitleIsSeparateFromDingTalkNameAndDefaultsAreCompatible() throws {
        var c = Conversation(); c.name = "项目群"; c.agent.workdir = "/tmp"
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(c.agent), as: UTF8.self).contains("sessionTitle"))
        XCTAssertEqual(try payload(c)["session_title"] as? String, "DWS · 群聊 · 项目群")
        c.kind = .contact; c.name = "联系人"
        XCTAssertEqual(try payload(c)["session_title"] as? String, "DWS · 私聊 · 联系人")
        c.agent.sessionTitle = "  自定义助手  "
        let saved = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(saved.name, "联系人")
        XCTAssertEqual(saved.agent.sessionTitle, c.agent.sessionTitle)
        XCTAssertEqual(try payload(saved)["session_title"] as? String, "自定义助手")
        for title in [String(repeating: "长", count: 121), "换\n行", "控制\u{0}"] {
            c.agent.sessionTitle = title
            XCTAssertThrowsError(try Validation.agent(c.agent))
        }
    }

    func testBridgeFailuresShowSafeActionableMessagesOnNonzeroExit() throws {
        for (reason, detail) in ["session_resume_failed": "历史会话恢复失败", "session_busy": "历史会话正被其他 Codex 客户端占用", "session_storage_unavailable": "无法准备 Codex 专用会话目录", "session_storage_failed": "会话绑定保存失败", "engine_timeout": "执行超时", "authentication_required": "登录已失效", "unknown": "执行失败"] {
            let json = try JSONSerialization.data(withJSONObject: ["error": "official_adapter_failed", "is_error": true, "reason": reason, "details": "secret-do-not-expose"])
            let result = CommandResult(status: 1, stdout: String(decoding: json, as: UTF8.self), stderr: "secret-do-not-expose")
            XCTAssertThrowsError(try Commands.finalAnswer(result, engine: .codex)) { error in
                XCTAssertTrue(error.localizedDescription.contains(detail))
                XCTAssertFalse(error.localizedDescription.contains("secret-do-not-expose"))
                XCTAssertFalse(error.localizedDescription.contains("official_adapter_failed"))
            }
        }
        let old = CommandResult(status: 1, stdout: "{\"error\":\"official_adapter_failed\",\"is_error\":true}", stderr: "")
        XCTAssertThrowsError(try Commands.finalAnswer(old, engine: .codex)) { error in
            XCTAssertTrue(error.localizedDescription.contains("执行失败"))
        }
        let success = CommandResult(status: 0, stdout: "{\"result\":\"最终回复\",\"session_recreated\":true,\"session_action\":\"recreated\",\"session_reference\":\"123456abcdef\"}", stderr: "")
        XCTAssertEqual(try Commands.finalAnswer(success, engine: .codex), "最终回复")
    }
}
