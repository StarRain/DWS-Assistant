import XCTest
@testable import DashboardCore

final class AgentProgressTests: XCTestCase {
    private func event(_ id: Int, kind: String = "command", status: String = "running") -> String {
        #"{"type":"dws_agent_progress","version":1,"id":""# + String(format: "%016x", id) + #"","kind":""# + kind + #"","status":""# + status + #""}"#
    }
    private func messages(_ content: String) throws -> [[String: Any]] {
        try JSONDecoder().decode([String].self, from: Data(content.utf8)).map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    private func components(_ content: String) throws -> [[String: Any]] {
        try XCTUnwrap(try messages(content).compactMap { ($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]] }.first)
    }
    private func reference() throws -> AICardReference {
        var conversation = Conversation(); conversation.profile = "corp:user"; conversation.stableID = "cid-progress"
        return try AICardReply(text: "思考中…", key: "key", processing: true).reference(
            from: CommandResult(status: 0, stdout: #"{"success":true,"bizId":"card-progress"}"#, stderr: ""), conversation: conversation)
    }

    func testOnlyBoundedValidatedLifecycleEventsAreRetained() {
        let buffer = AgentProgressBuffer()
        for invalid in ["not json", event(1).replacingOccurrences(of: "dws_agent_progress", with: "reasoning"),
                        event(1).replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                        event(1, kind: "reasoning"), event(1, status: "invented"),
                        event(1).replacingOccurrences(of: "0000000000000001", with: "private-id"),
                        String(repeating: " ", count: 1_025) + event(1)] { buffer.receive(line: invalid) }
        XCTAssertTrue(buffer.snapshot.isEmpty)
        buffer.receive(line: event(1)); buffer.receive(line: event(1))
        buffer.receive(line: event(1, kind: "tool", status: "completed"))
        buffer.receive(line: event(1, status: "failed"))
        buffer.receive(line: event(1)); buffer.receive(line: event(1, status: "completed"))
        XCTAssertEqual(buffer.snapshot.revision, 2)
        XCTAssertEqual(buffer.snapshot.steps.first?.status, .failed)
        for id in 2...1_000 { buffer.receive(line: event(id)) }
        buffer.receive(line: event(128, status: "completed"))
        XCTAssertEqual(buffer.snapshot.steps.count, 128)
        XCTAssertEqual(buffer.snapshot.steps.last?.status, .completed)
        XCTAssertTrue(buffer.snapshot.components(running: false).contains { $0["id"] as? String == "execution-limit" })
    }

    func testProgressUsesSameSurfaceAndClearsEffectsOnFinalResult() throws {
        let buffer = AgentProgressBuffer(), reference = try reference()
        buffer.receive(line: event(1, kind: "dws")); buffer.receive(line: event(2))
        let live = try AICardReply.progressContent(reference, progress: buffer.snapshot)
        XCTAssertFalse(live.contains("createSurface"))
        XCTAssertTrue(try messages(live).allSatisfy { ($0["updateComponents"] as? [String: Any])?["surfaceId"] as? String == reference.surfaceID })
        let liveComponents = try components(live)
        XCTAssertEqual(liveComponents.first { $0["id"] as? String == "execution-progress" }?["textEffect"] as? String, "shimmer")
        XCTAssertTrue(live.contains("正在执行"))
        buffer.receive(line: event(1, kind: "dws", status: "completed")); buffer.receive(line: event(2, status: "failed"))
        let final = try AICardReply(text: "结果正文", key: "key", surfaceID: reference.surfaceID, progress: buffer.snapshot)
        let done = try components(final.replacementContent)
        XCTAssertFalse(final.replacementContent.contains("shimmer")); XCTAssertFalse(final.replacementContent.contains("loading_circular"))
        XCTAssertEqual(done.first { $0["id"] as? String == "execution-dws" }?["icon"] as? String, "Check_L_outlined")
        XCTAssertNil(done.first { $0["id"] as? String == "execution-command" }?["icon"])
        XCTAssertTrue(final.replacementContent.contains("已使用 DWS 完成 1 项操作"))
        XCTAssertTrue(final.replacementContent.contains("1 条失败"))
        XCTAssertFalse(final.replacementContent.contains("defaultExpanded"))
    }

    func testEveryCardStateKeepsExactAttributionAsLastChild() throws {
        let reference = try reference(), buffer = AgentProgressBuffer()
        buffer.receive(line: event(1))
        var conversation = Conversation(); conversation.profile = "corp:user"; conversation.stableID = "cid-progress"
        let form = #"{"kind":"dws_interaction","text":"确认？","questions":[{"id":"choice","label":"选择","type":"single","options":[{"id":"yes","label":"是"},{"id":"no","label":"否"}]}]}"#
        let variants = [reference.creationContent,
            try AICardReply.progressContent(reference, progress: buffer.snapshot),
            try AICardReply(text: "完成", key: "key", progress: buffer.snapshot).replacementContent,
            try AICardReply(text: form, key: "key", conversation: conversation, progress: buffer.snapshot).replacementContent,
            try AICardReply.statusContent(reference, status: "失败", progress: buffer.snapshot),
            try AICardReply.statusContent(reference, status: "已取消"),
            try AICardReply.statusContent(reference, status: "已过期")]
        for variant in variants {
            let items = try components(variant)
            XCTAssertEqual((items.first { $0["id"] as? String == "root" }?["children"] as? [String])?.last, "ai-attribution")
            let footer = items.filter { $0["id"] as? String == "ai-attribution" }
            XCTAssertEqual(footer.count, 1)
            XCTAssertEqual(footer.first?["text"] as? String, "「此消息由DWS助手通过DWS CLI自动回复」")
        }
        let failure = try AICardReply.statusContent(reference, status: "失败", progress: buffer.snapshot)
        XCTAssertTrue(failure.contains("已停止")); XCTAssertFalse(failure.contains("shimmer")); XCTAssertFalse(failure.contains("Check_L_outlined"))
    }

    func testProgressOptInDoesNotChangeCodexSessionBinding() throws {
        var settings = AgentSettings(); settings.workdir = "/tmp"
        func payload(_ enabled: Bool) throws -> [String: Any] {
            let spec = try Commands.officialAgent(settings, prompt: "本轮消息", route: "route", bridgePath: "/bin/echo", stateDirectory: "/tmp", config: DashboardConfig(), reportProgress: enabled)
            return try JSONSerialization.jsonObject(with: Data(XCTUnwrap(spec.stdin).utf8)) as! [String: Any]
        }
        let original = try payload(false), progress = try payload(true)
        XCTAssertNil(original["report_progress"]); XCTAssertEqual(progress["report_progress"] as? Bool, true)
        for key in ["scope_id", "codex_home", "conversation_id", "text"] { XCTAssertEqual(original[key] as? String, progress[key] as? String) }
        settings.engine = .claude
        XCTAssertNil(try payload(true)["report_progress"])
    }
}
