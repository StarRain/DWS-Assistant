import XCTest
@testable import AssistantCore
@testable import DWSAssistant

@MainActor
final class CardProgressUpdatesTests: XCTestCase {
    private let started = #"{"type":"dws_agent_progress","version":1,"id":"0000000000000001","kind":"command","status":"running"}"#
    private let completed = #"{"type":"dws_agent_progress","version":1,"id":"0000000000000001","kind":"command","status":"completed"}"#

    private func fixture(failing: Bool = false, check: @escaping @MainActor () throws -> Void = {}) throws -> (CardProgressUpdates, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-progress-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let dws = directory.appendingPathComponent("dws")
        let script = #"""
        #!/bin/bash
        base="$(cd "$(dirname "$0")" && pwd)"
        /bin/cat > "$base/update-body"
        echo update >> "$base/updates"
        if [[ -f "$base/fail" ]]; then
          echo '{"success":false}'
          exit 1
        fi
        /bin/sleep 0.2
        echo done >> "$base/completed-updates"
        echo '{"success":true,"bizId":"test-card"}'
        """#
        try script.write(to: dws, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dws.path)
        if failing { try Data().write(to: directory.appendingPathComponent("fail")) }
        var config = AssistantConfig(); config.executablePaths = ["dws": dws.path]
        let reference = AICardReference(bizID: "test-card", surfaceID: "surface-test", profile: "corp:user", target: "cid-test", creationContent: "", finishContent: "")
        return (CardProgressUpdates(reference: reference, config: config, interval: .milliseconds(30), checkCurrent: check), directory)
    }

    private func engine(in directory: URL, waitsForUpdate: Bool = false) -> CommandSpec {
        let body = """
        printf '%s\\n' '\(started)' >&2
        \(waitsForUpdate ? "while [[ ! -f \"$1/updates\" ]]; do /bin/sleep 0.01; done" : "while true; do /bin/sleep 0.02; done")
        printf '%s\\n' '\(completed)' >&2
        echo '{"result":"answer","adapter":"dws-official"}'
        echo done > "$1/engine-finished"
        """
        return CommandSpec(executable: "/bin/bash", arguments: ["-c", body, "engine-fixture", directory.path], timeout: 3)
    }
    private func waitFor(_ file: URL) async throws {
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("fixture did not reach \(file.lastPathComponent)")
    }

    func testProgressArrivesBeforeFinalAndInflightUpdateDrainsBeforeReturn() async throws {
        let (updates, directory) = try fixture()
        let result = try await updates.run(engine(in: directory, waitsForUpdate: true))
        XCTAssertEqual(try Commands.finalAnswer(result, engine: .codex), "answer")
        XCTAssertEqual(updates.snapshot.steps.first?.status, .completed)
        XCTAssertFalse(updates.uncertain)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine-finished").path))
        // The engine finished while the slower card request was in flight.
        // run must wait for that request so it cannot overwrite the final card.
        let writes = try String(contentsOf: directory.appendingPathComponent("updates"), encoding: .utf8)
        let finished = try String(contentsOf: directory.appendingPathComponent("completed-updates"), encoding: .utf8)
        XCTAssertEqual(writes.split(separator: "\n").count, 1)
        XCTAssertEqual(finished.split(separator: "\n").count, 1)
        let body = try String(contentsOf: directory.appendingPathComponent("update-body"), encoding: .utf8)
        XCTAssertTrue(body.contains("正在执行")); XCTAssertTrue(body.contains("「此消息由DWS助手通过DWS CLI自动回复」"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("updates"), encoding: .utf8), writes)
    }

    func testUncertainProgressUpdateStopsEngineWithoutRetry() async throws {
        let (updates, directory) = try fixture(failing: true)
        do { _ = try await updates.run(engine(in: directory)); XCTFail("expected progress failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("进度更新结果待确认")) }
        XCTAssertTrue(updates.uncertain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("engine-finished").path))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("updates"), encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testChangedConversationStopsBeforeProgressWrite() async throws {
        let (updates, directory) = try fixture(check: { throw AssistantError.cancelled })
        do { _ = try await updates.run(engine(in: directory)); XCTFail("expected cancellation") } catch {}
        XCTAssertFalse(updates.uncertain)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("updates").path))
    }

    func testCancellationDoesNotLeaveBackgroundProgressWriter() async throws {
        let (updates, directory) = try fixture()
        let task = Task { try await updates.run(engine(in: directory)) }
        try await waitFor(directory.appendingPathComponent("updates"))
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch {}
        let writes = try String(contentsOf: directory.appendingPathComponent("updates"), encoding: .utf8)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("updates"), encoding: .utf8), writes)
    }

    func testAnswerWithoutProgressDoesNotCreateSpuriousUpdate() async throws {
        let (updates, directory) = try fixture()
        let result = try await updates.run(CommandSpec(executable: "/bin/echo", arguments: [#"{"result":"answer"}"#]))
        XCTAssertEqual(try Commands.finalAnswer(result, engine: .codex), "answer")
        XCTAssertTrue(updates.snapshot.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("updates").path))
    }
}
