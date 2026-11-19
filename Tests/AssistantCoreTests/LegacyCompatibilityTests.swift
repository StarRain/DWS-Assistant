import XCTest
@testable import AssistantCore

final class LegacyCompatibilityTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-migration-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func write(_ data: Data, to path: URL) throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }

    func testRenamedScopesKeepCodexHistoryAndOtherEngineBindings() throws {
        let root = try directory(), route = "account|group|chat", key = Digest.sha256(route), thread = UUID().uuidString.lowercased()
        let connect = root.appendingPathComponent("agent-sessions/connect")
        let old = connect.appendingPathComponent(LegacyCompatibility.codexScopePrefix + key)
        let binding = try JSONEncoder().encode([key: thread])
        try write(binding, to: old.appendingPathComponent("codex-threads.json"))
        let rollout = root.appendingPathComponent("codex/sessions/rollout-fixture-\(thread).jsonl")
        let item: [String: Any] = ["type": "event_msg", "payload": ["type": "item_completed", "turn_id": "turn", "item": ["type": "AgentMessage", "id": "answer", "content": [["type": "Text", "text": "preserved reply"]]]]]
        var history = try JSONSerialization.data(withJSONObject: item); history.append(10)
        try write(history, to: rollout)
        let previous = try CodexHistory.load(route: route, dataDirectory: root)
        XCTAssertEqual(previous.entries.first?.text, "preserved reply")
        let other = connect.appendingPathComponent(LegacyCompatibility.engineScopePrefix + key)
        try write(Data("existing-engine-session".utf8), to: other.appendingPathComponent("state.json"))
        let lock = root.appendingPathComponent("codex/" + LegacyCompatibility.codexStorageLock)
        try write(Data(), to: lock)

        try AssistantPaths.migrateStoredNames(in: root)
        let current = connect.appendingPathComponent(CodexHistory.scope(route: route))
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("codex-threads.json")), binding)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: old.path), current.path)
        XCTAssertEqual(try Data(contentsOf: connect.appendingPathComponent("assistant-\(key)/state.json")), Data("existing-engine-session".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: lock.path), root.appendingPathComponent("codex/.assistant-storage.lock").path)
        XCTAssertEqual(try CodexHistory.load(route: route, dataDirectory: root).entries.map(\.text), previous.entries.map(\.text))
        try AssistantPaths.migrateStoredNames(in: root)
        XCTAssertEqual(try Data(contentsOf: current.appendingPathComponent("codex-threads.json")), binding)
        XCTAssertEqual(try Data(contentsOf: rollout), history)
        var settings = AgentSettings(); settings.workdir = root.path
        let request = try Commands.officialAgent(settings, prompt: "next message", route: route, bridgePath: "/bin/echo",
            stateDirectory: root.appendingPathComponent("agent-sessions").path, config: AssistantConfig())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.stdin!.utf8)) as? [String: Any])
        XCTAssertEqual(payload["scope_id"] as? String, current.lastPathComponent)
        XCTAssertEqual(payload["conversation_id"] as? String, key)
    }

    func testConflictingBindingsAreNotOverwrittenOrMerged() throws {
        let root = try directory(), key = Digest.sha256("route")
        let connect = root.appendingPathComponent("agent-sessions/connect")
        let old = connect.appendingPathComponent(LegacyCompatibility.codexScopePrefix + key + "/codex-threads.json")
        let new = connect.appendingPathComponent("assistant-codex-v3-" + key + "/codex-threads.json")
        try write(Data("old binding".utf8), to: old); try write(Data("new binding".utf8), to: new)
        XCTAssertThrowsError(try AssistantPaths.migrateStoredNames(in: root))
        XCTAssertEqual(try Data(contentsOf: old), Data("old binding".utf8))
        XCTAssertEqual(try Data(contentsOf: new), Data("new binding".utf8))
        XCTAssertNil(LegacyCompatibility.currentScope(for: LegacyCompatibility.retiredCodexScopePrefix + key))
        XCTAssertNil(LegacyCompatibility.currentScope(for: LegacyCompatibility.engineScopePrefix + "user-folder"))
    }

    func testPrivateWorkspaceRenameKeepsOtherEngineSession() throws {
        let home = try directory(), route = "account|contact|person"
        let data = home.appendingPathComponent(".dws-assistant"), state = data.appendingPathComponent("agent-sessions")
        let workspace = state.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let oldData = home.appendingPathComponent(LegacyCompatibility.dataDirectoryNames[0])
        try FileManager.default.createSymbolicLink(at: oldData, withDestinationURL: data)
        var previous = AgentSettings(); previous.engine = .pi
        previous.workdir = oldData.appendingPathComponent("agent-sessions/workspace").path
        // Fixture for the persisted scope format used before the app rename.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let hash = Digest.sha256(route + String(decoding: try encoder.encode(previous), as: UTF8.self))
        let old = state.appendingPathComponent("connect/" + LegacyCompatibility.engineScopePrefix + hash)
        try write(Data("original-session".utf8), to: old.appendingPathComponent("pi-session.json"))
        try AssistantPaths.migrateStoredNames(in: data)
        var settings = AgentSettings(); settings.engine = .pi
        let request = try Commands.officialAgent(settings, prompt: "next message", route: route, bridgePath: "/bin/echo", stateDirectory: state.path, config: AssistantConfig())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.stdin!.utf8)) as? [String: Any])
        let scope = try XCTUnwrap(payload["scope_id"] as? String)
        XCTAssertTrue(scope.hasPrefix("assistant-"))
        XCTAssertEqual(try Data(contentsOf: state.appendingPathComponent("connect/\(scope)/pi-session.json")), Data("original-session".utf8))
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("pi-session.json")), Data("original-session".utf8))
        XCTAssertEqual(payload["workdir"] as? String, workspace.path)
    }
}
