import XCTest
@testable import AssistantCore

final class EnginePermissionTests: XCTestCase {
    func testLegacyFullRemainsAutoReviewAndNewModesRoundTrip() throws {
        let legacy = Data(#"{"engine":"codex","model":"","authorizedDirectories":[],"permission":"full","timeout":120}"#.utf8)
        let settings = try JSONDecoder().decode(AgentSettings.self, from: legacy)
        XCTAssertEqual(settings.permission, .full)
        XCTAssertEqual(settings.permission.codexMode, "auto_review")
        var scopes = Set<String>()
        for permission in ExecutionPermission.options(for: .codex) {
            var value = settings; value.permission = permission
            XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(value)), value)
            let spec = try Commands.officialAgent(value, prompt: "fixture", route: "route", bridgePath: "/bin/echo", stateDirectory: "/tmp/approval-tests", config: AssistantConfig())
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(spec.stdin).utf8)) as? [String: Any])
            XCTAssertEqual(body["permission_mode"] as? String, permission.codexMode)
            XCTAssertEqual(body["interactive_approvals"] as? Bool, permission == .requestApproval)
            XCTAssertEqual(spec.keepInputOpen, permission == .requestApproval)
            scopes.insert(try XCTUnwrap(body["scope_id"] as? String))
            if permission == .requestApproval { XCTAssertTrue(spec.streaming); XCTAssertTrue(spec.stdin!.hasSuffix("\n")) }
        }
        XCTAssertEqual(scopes.count, 1, "Changing permissions applies on the existing conversation")
    }

    func testOtherEnginesCannotAccidentallyReceiveCodexModes() throws {
        for engine in Engine.allCases where engine != .codex {
            for permission in [ExecutionPermission.requestApproval, .fullAccess] {
                var settings = AgentSettings(); settings.engine = engine; settings.permission = permission
                settings.agentCommand = "/bin/echo"
                XCTAssertThrowsError(try Validation.agent(settings))
            }
            XCTAssertEqual(ExecutionPermission.options(for: engine), [.restricted, .full])
        }
        var c = Conversation(); c.autoReply = true; c.replyFormat = .text
        c.agent.permission = .requestApproval
        XCTAssertTrue(c.needsCardEvents, "Native approvals work even when replies use text")
        c.agent.permission = .full
        XCTAssertFalse(c.needsCardEvents)
    }

    func testNativeRequestValidationAndExpiredResponsesFailClosed() throws {
        let now = Date()
        var body: [String: Any] = ["type":"dws_engine_approval", "version":1, "token":String(repeating: "a", count: 64),
                                   "kind":"command", "details":#"{"command":"printf fixture"}"#, "expires_at":now.addingTimeInterval(60).timeIntervalSince1970 * 1_000]
        func line(_ value: [String: Any]) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
        let request = try XCTUnwrap(EngineApprovalRequest.parse(try line(body), now: now))
        XCTAssertTrue(try request.response(approved: true, now: now).contains("accept"))
        XCTAssertTrue(try request.response(approved: true, now: now.addingTimeInterval(61)).contains("decline"))
        for (key, value) in [("type", "dws_interaction"), ("token", "invented"), ("kind", "shell"), ("details", "")] {
            var invalid = body; invalid[key] = value
            XCTAssertNil(EngineApprovalRequest.parse(try line(invalid), now: now))
        }
        for offset in [-1.0, 96.0] {
            body["expires_at"] = now.addingTimeInterval(offset).timeIntervalSince1970 * 1_000
            XCTAssertNil(EngineApprovalRequest.parse(try line(body), now: now))
        }
        var c = Conversation(); c.profile = "corp:user"; c.stableID = "cid-test"; c.cardInteractionTimeout = 3600
        let card = try request.card(conversation: c, conversationID: c.stableID)
        XCTAssertEqual(try XCTUnwrap(card.interaction).expiresAt, request.deadline, "Native requests keep their engine deadline")
        XCTAssertTrue(card.body.contains("printf fixture"))
        XCTAssertTrue(card.interaction!.form.questions.isEmpty)
        body["expires_at"] = now.addingTimeInterval(60).timeIntervalSince1970 * 1_000
        body["details"] = String(repeating: "x", count: 5_000) + " tail-operation"
        let longRequest = try XCTUnwrap(EngineApprovalRequest.parse(try line(body), now: now))
        XCTAssertTrue(longRequest.displayDetails.hasSuffix("tail-operation"), "Do not hide the end of the action being approved")
        body["details"] = String(repeating: "\"", count: 40_000)
        XCTAssertNotNil(EngineApprovalRequest.parse(try line(body), now: now), "The envelope may exceed 64 KiB after JSON escaping")
    }
}
