import XCTest
import Darwin
@testable import AssistantCore

final class DataDirectoryMigrationTests: XCTestCase {
    func testDefaultDirectoryUsesAssistantNameAndKeepsLegacyLookupOrder() {
        XCTAssertEqual(AssistantPaths.dataDirectory.lastPathComponent, ".dws-assistant")
        XCTAssertEqual(AssistantPaths.legacyDirectories.map(\.lastPathComponent), LegacyCompatibility.dataDirectoryNames.map { URL(fileURLWithPath: $0).lastPathComponent })
    }

    func testCompleteStoreAndAbsoluteEnginePathsSurviveRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent(LegacyCompatibility.dataDirectoryNames[0]), target = root.appendingPathComponent(".dws-assistant")
        let files = ["config.json", "activity.json", "delivery-ledger.json", "agent-sessions/connect/scope/codex-threads.json",
                     "codex/state_5.sqlite", "codex/state_5.sqlite-wal", "codex/sessions/rollout.jsonl", "agent-workspace/artifact.txt"]
        for name in files {
            let path = source.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(name.utf8).write(to: path)
        }
        try AssistantPaths.migrateLegacy(from: source, to: target)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: source.path), target.path)
        XCTAssertFalse(try target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink ?? true)
        for name in files {
            XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent(name)), Data(name.utf8))
            XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(name)), Data(name.utf8))
        }
        // Both old and new launches must lock the same inode after migration.
        let active = Darwin.open(target.appendingPathComponent("instance.lock").path, O_RDWR)
        defer { if active >= 0 { flock(active, LOCK_UN); Darwin.close(active) } }
        XCTAssertGreaterThanOrEqual(active, 0); XCTAssertEqual(flock(active, LOCK_EX | LOCK_NB), 0)
        let legacy = Darwin.open(source.appendingPathComponent("instance.lock").path, O_RDWR)
        defer { if legacy >= 0 { Darwin.close(legacy) } }
        XCTAssertGreaterThanOrEqual(legacy, 0); XCTAssertNotEqual(flock(legacy, LOCK_EX | LOCK_NB), 0)
        try AssistantPaths.migrateLegacy(from: source, to: target)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("config.json")), Data("config.json".utf8))
    }

    func testRunningLegacyInstanceBlocksMigrationWithoutChangingItsData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old"), target = root.appendingPathComponent("new")
        let store = try JSONStore(directory: source)
        try store.save(["kept": true], to: "config.json")
        let lock = Darwin.open(source.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
        defer { if lock >= 0 { flock(lock, LOCK_UN); Darwin.close(lock) } }
        XCTAssertEqual(flock(lock, LOCK_EX | LOCK_NB), 0)
        XCTAssertThrowsError(try AssistantPaths.migrateLegacy(from: source, to: target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(try store.load("config.json", as: [String: Bool].self), ["kept": true])
    }
}
