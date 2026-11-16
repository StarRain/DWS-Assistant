import XCTest
@testable import DashboardCore

final class CodexHistoryTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-history-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    private func write(_ lines: [[String: Any]], to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = try lines.map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    private func item(_ type: String, id: String, turn: String, text: String) -> [String: Any] {
        ["timestamp": "2026-11-16T05:00:00Z", "type": "event_msg", "payload": ["type": "item_completed", "turn_id": turn,
            "item": ["type": type, "id": id, "content": [["type": "Text", "text": text]]]]]
    }

    func testHistoryShowsMessagesAndExecutionWithoutInternalContentOrDuplicates() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.jsonl")
        try write([
            ["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [["type": "input_text", "text": "internal instructions"]]]],
            ["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "same question"]]]],
            item("UserMessage", id: "u1", turn: "turn-one", text: "same question"),
            item("UserMessage", id: "u1", turn: "turn-one", text: "same question"),
            item("Reasoning", id: "r1", turn: "turn-one", text: "private reasoning"),
            ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn-one", "item": ["type": "CommandExecution", "id": "cmd", "command": ["ls", "Sources"], "aggregated_output": "access_token=secret-value", "exit_code": 0]]],
            item("AgentMessage", id: "a1", turn: "turn-one", text: "answer one"),
            ["type": "response_item", "payload": ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "answer one"]]]],
            item("UserMessage", id: "u1", turn: "turn-two", text: "same question")
        ], to: file)
        let original = try Data(contentsOf: file)
        let result = try CodexHistory.read(file: file)
        XCTAssertEqual(result.entries.map(\.kind), [.user, .execution, .assistant, .user])
        XCTAssertEqual(result.entries.filter { $0.text == "same question" }.count, 2)
        XCTAssertTrue(result.entries[1].detail.contains("ls Sources"))
        XCTAssertFalse(result.entries.map { $0.text + $0.detail }.joined().contains("secret-value"))
        XCTAssertFalse(result.entries.map(\.text).joined().contains("internal instructions"))
        XCTAssertFalse(result.entries.map(\.text).joined().contains("private reasoning"))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let recent = try CodexHistory.read(file: file, limit: 2)
        XCTAssertEqual(recent.entries.map(\.kind), [.assistant, .user])
        XCTAssertTrue(recent.hasEarlier)
    }

    func testHistoryUsesOnlyNewBindingAndDedicatedStorage() throws {
        let data = try temporaryDirectory(), route = "account|group|one", thread = UUID().uuidString.lowercased()
        let key = Digest.sha256(route)
        let oldBinding = data.appendingPathComponent("agent-sessions/connect/dashboard-codex-v2-\(key)-project-policy-v1/codex-threads.json")
        try FileManager.default.createDirectory(at: oldBinding.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([key: thread]).write(to: oldBinding)
        let oldData = try Data(contentsOf: oldBinding)
        let relative = "sessions/2026/11/16/rollout-fixture-\(thread).jsonl"
        let file = data.appendingPathComponent("codex/" + relative)
        try write([item("UserMessage", id: "one", turn: "t", text: "panel history")], to: file)
        XCTAssertTrue(try CodexHistory.load(route: route, dataDirectory: data).entries.isEmpty)

        let binding = data.appendingPathComponent("agent-sessions/connect/\(CodexHistory.scope(route: route))/codex-threads.json")
        try FileManager.default.createDirectory(at: binding.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode([key: thread]).write(to: binding)
        XCTAssertEqual(try CodexHistory.load(route: route, dataDirectory: data).entries.first?.text, "panel history")
        XCTAssertTrue(try CodexHistory.load(route: "account|group|two", dataDirectory: data).entries.isEmpty)
        XCTAssertEqual(try Data(contentsOf: oldBinding), oldData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("codex/thread-writer-locks").path))

        let external = try temporaryDirectory().appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: external.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: external)
        XCTAssertTrue(try CodexHistory.load(route: route, dataDirectory: data).entries.isEmpty)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        XCTAssertTrue(try CodexHistory.load(route: route, dataDirectory: data).entries.isEmpty)
    }

    func testPartialAppendAndLongMessagesRemainReadable() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.jsonl")
        let answer = String(repeating: "完整回复", count: 1_500)
        try write([
            ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "t", "item": ["type": "UserMessage", "id": "u", "content": [["type": "text", "text": "question"], ["type": "image", "url": "private-image"]]]]],
            item("AgentMessage", id: "a", turn: "t", text: answer)
        ], to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"partial":"#.utf8)); try handle.close()
        let result = try CodexHistory.read(file: file)
        XCTAssertEqual(result.entries.map(\.text), ["question\n[图片]", answer])
    }

    func testHostPromptDisplaysOnlyCurrentMessageAndImages() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.jsonl")
        let payload: [String: Any] = ["message": "看看这张图", "attached_images": ["/private/image.jpg"], "recent_conversation": ["earlier message"]]
        let prompt = "你是钉钉会话回复助手。\ninternal instructions\n" + String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        try write([
            ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "t", "item": ["type": "UserMessage", "id": "u", "content": [["type": "text", "text": prompt], ["type": "localImage", "path": "/private/image.jpg"]]]]],
            item("UserMessage", id: "u2", turn: "t2", text: #"{"message":"keep user JSON unchanged"}"#)
        ], to: file)
        let result = try CodexHistory.read(file: file)
        XCTAssertEqual(result.entries.map(\.text), ["看看这张图\n[图片]", #"{"message":"keep user JSON unchanged"}"#])
    }

    func testCodexRequestKeepsProjectDirectoryAndUsesPrivateStorage() throws {
        let data = try temporaryDirectory()
        var settings = AgentSettings(); settings.workdir = data.path
        let spec = try Commands.officialAgent(settings, prompt: "hello", route: "route", bridgePath: "/bin/echo",
            stateDirectory: data.appendingPathComponent("agent-sessions").path, config: DashboardConfig())
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(spec.stdin!.utf8)) as? [String: Any])
        XCTAssertEqual(body["codex_home"] as? String, data.appendingPathComponent("codex").path)
        XCTAssertEqual(body["scope_id"] as? String, CodexHistory.scope(route: "route"))
        XCTAssertNil(body["legacy_scope_id"])
        XCTAssertEqual(body["workdir"] as? String, data.path)
        XCTAssertEqual(body["authorized_directories"] as? [String], [data.path])
    }

    func testCardSubmissionShowsConfirmationAndAnswersWithoutHostInstructions() throws {
        let file = try temporaryDirectory().appendingPathComponent("history.jsonl")
        let payload: [String: Any] = ["confirmed": "确认并继续", "card": "运行构建脚本？", "answers": [["question": "环境", "selected": ["测试"]], ["question": "备注", "text": "检查产物路径"]]]
        let prompt = "当前账号通过本面板发出的交互卡片提交了确认或补充信息。\ninternal instructions\n" + String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        try write([item("UserMessage", id: "u", turn: "t", text: prompt)], to: file)
        XCTAssertEqual(try CodexHistory.read(file: file).entries.first?.text, "确认并继续\n\n运行构建脚本？\n\n环境: 测试\n\n备注: 检查产物路径")
    }
}
