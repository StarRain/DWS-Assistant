import XCTest
@testable import DashboardCore

@MainActor
final class LoginWatcherTests: XCTestCase {
    func testAtomicReplacementDeletionRecreationAndUnrelatedWrites() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("login-watch-" + UUID().uuidString)
        let root = parent.appendingPathComponent(".dws")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        var changes = 0
        let watcher = DWSLoginWatcher(directories: [root]) { changes += 1 }
        watcher.start(); defer { watcher.stop() }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let profile = root.appendingPathComponent("profiles.json")
        try Data("one".utf8).write(to: profile, options: .atomic)
        for _ in 0..<100 where changes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(changes, 0, "First login creates a previously missing auth directory")
        var baseline = changes
        try Data("two".utf8).write(to: profile, options: .atomic)
        for _ in 0..<100 where changes == baseline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(changes, baseline)
        baseline = changes
        try Data("ignore".utf8).write(to: root.appendingPathComponent("version-cache.json"), options: .atomic)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(changes, baseline, "The status check's own unrelated files must not cause a refresh loop")
        try FileManager.default.removeItem(at: root)
        for _ in 0..<100 where changes == baseline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(changes, baseline)
        baseline = changes
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("three".utf8).write(to: profile, options: .atomic)
        for _ in 0..<100 where changes == baseline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertGreaterThan(changes, baseline, "Deleted directory/file watchers must be rebound after re-login")
        watcher.stop(); baseline = changes
        try Data("four".utf8).write(to: profile, options: .atomic)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(changes, baseline)
    }
}
