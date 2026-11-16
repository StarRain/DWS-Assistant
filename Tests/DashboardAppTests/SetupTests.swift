import XCTest
import DashboardCore
@testable import DWSAssistant

@MainActor
final class SetupTests: XCTestCase {
    private let signedIn = #"{"success":true,"authenticated":true,"corp_id":"corp","user_id":"user","user_name":"引导测试","corp_name":"测试组织"}"#
    private let script = #"""
    #!/bin/bash
    base="$(cd "$(dirname "$0")" && pwd)"
    printf '%s\n' "$*" >> "$base/commands"
    if [[ "$1 $2" == "auth status" ]]; then
      [[ -f "$base/delay" ]] && /bin/sleep 0.25
      /bin/cat "$base/status.json"
    elif [[ "$1 $2" == "auth login" ]]; then
      echo '模拟官方授权流程'
      /bin/cp "$base/authorized.json" "$base/status.json"
    elif [[ "$1 $2" == "auth logout" ]]; then
      if [[ -f "$base/logout-fails" ]]; then echo '模拟退出失败' >&2; exit 1; fi
      echo '{"authenticated":false}' > "$base/status.json"
      echo '[OK] 已清除认证信息'
    else
      echo 'unexpected command' >&2; exit 1
    fi
    """#

    private func fixture(installed: Bool, status: String = #"{"authenticated":false}"#, completed: Bool = false) throws -> (DashboardModel, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-setup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try status.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try signedIn.write(to: dir.appendingPathComponent("authorized.json"), atomically: true, encoding: .utf8)
        if installed { try installMock(in: dir) }
        var config = DashboardConfig()
        config.setupCompleted = completed
        config.executablePaths = Dictionary(uniqueKeysWithValues: (["dws"] + Engine.executableNames).map { ($0, dir.appendingPathComponent($0).path) })
        try JSONStore(directory: dir.appendingPathComponent("state")).save(config, to: "config.json")
        return (DashboardModel(directory: dir.appendingPathComponent("state"), authDirectories: [dir]), dir)
    }

    private func installMock(in dir: URL) throws {
        let path = dir.appendingPathComponent("dws")
        try script.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    func testMissingInstallIsDetectedAgainWithoutRestartAndDoesNotRunCommands() async throws {
        let (model, dir) = try fixture(installed: false, status: signedIn)
        XCTAssertTrue(model.needsSetup)
        await model.refreshAccounts()
        XCTAssertFalse(model.dwsInstalled)
        XCTAssertEqual(model.accountCheckState, .unavailable)
        model.completeSetup(); model.login()
        XCTAssertTrue(model.needsSetup)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("commands").path))
        try installMock(in: dir)
        model.refreshDWSInstallation()
        for _ in 0..<100 where !model.accountOK { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.dwsInstalled)
        XCTAssertTrue(model.canCompleteSetup)
        XCTAssertFalse(model.personalRunning)
    }

    func testRepeatedInstallationRefreshDoesNotRecheckLoginOrOtherEngines() async throws {
        let (model, dir) = try fixture(installed: true)
        await model.refreshAccounts()
        let accountDetail = model.accountDetail
        let paths = model.detectedPaths
        // An engine becoming available must not broaden the DWS card's refresh.
        model.config.executablePaths["codex"] = dir.appendingPathComponent("dws").path
        for _ in 0..<3 { model.refreshDWSInstallation() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.detectedPaths, paths)
        XCTAssertEqual(model.accountDetail, accountDetail)
        XCTAssertEqual(model.accountCheckState, .signedOut)
        XCTAssertFalse(model.refreshing)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8), "auth status --readonly --format json\n")
    }

    func testLoginAutomaticallyRechecksAndFinishingOnlyPersistsSetup() async throws {
        let (model, dir) = try fixture(installed: true)
        await model.refreshAccounts()
        XCTAssertEqual(model.accountCheckState, .signedOut)
        XCTAssertFalse(model.canCompleteSetup)
        model.completeSetup(); XCTAssertTrue(model.needsSetup)
        model.login()
        for _ in 0..<100 where !model.accountOK { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.accountOK)
        XCTAssertTrue(model.installedEngines.isEmpty)
        XCTAssertTrue(model.canCompleteSetup, "Engine installation is optional for browsing/listening configuration")
        model.completeSetup()
        XCTAssertFalse(model.needsSetup)
        XCTAssertFalse(model.personalRunning)
        XCTAssertEqual(model.receivedCount, 0)
        let stored = try JSONStore(directory: model.dataURL).load("config.json", as: DashboardConfig.self)
        XCTAssertEqual(stored?.setupCompleted, true)
        XCTAssertEqual(stored?.conversations, [])
        let commands = try String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.map(String.init), ["auth status --readonly --format json", "auth login --device", "auth status --readonly --format json"])
    }

    func testUnreadableStatusCannotCompleteSetupOrAutomaticallyLaunchLogin() async throws {
        let (model, dir) = try fixture(installed: true, status: #"{"authenticated":false,"reason":"keychain_unavailable","message":"暂时无法读取"}"#)
        await model.refreshAccounts()
        XCTAssertEqual(model.accountCheckState, .indeterminate)
        XCTAssertFalse(model.accountOK)
        model.completeSetup()
        XCTAssertTrue(model.needsSetup)
        XCTAssertFalse(model.loggingIn)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8), "auth status --readonly --format json\n")
        try signedIn.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        await model.refreshAccounts()
        XCTAssertTrue(model.canCompleteSetup)
    }

    func testConcurrentChecksDoNotDuplicateWorkOrAllowStaleCompletion() async throws {
        let (model, dir) = try fixture(installed: true, status: signedIn)
        await model.refreshAccounts()
        try Data().write(to: dir.appendingPathComponent("delay"))
        try #"{"authenticated":false}"#.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        let check = Task { await model.refreshAccounts() }
        for _ in 0..<50 where !model.refreshing { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.refreshing)
        XCTAssertFalse(model.canCompleteSetup)
        model.completeSetup(); XCTAssertTrue(model.needsSetup)
        await model.refreshAccounts()
        await check.value
        XCTAssertEqual(model.accountCheckState, .signedOut)
        let commands = try String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.count, 2)
    }

    func testReturningUserIsBlockedBeforeCheckAndAfterLogoutAndRestoresConversations() async throws {
        let (model, dir) = try fixture(installed: true, status: signedIn, completed: true)
        var config = model.config
        var conversation = Conversation(); conversation.profile = "corp:user"; conversation.stableID = "cid-existing"; conversation.name = "已有群聊"
        config.conversations = [conversation]; try model.persist(config)
        XCTAssertTrue(model.needsSetup, "A persisted completion flag cannot bypass checking the current login")
        await model.refreshAccounts(); XCTAssertFalse(model.needsSetup)
        try #"{"authenticated":false}"#.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        model.personalRunning = true
        await model.refreshAccounts()
        XCTAssertTrue(model.needsSetup); XCTAssertFalse(model.personalRunning)
        XCTAssertEqual(model.config.conversations, [conversation])
        model.startPersonal(); XCTAssertFalse(model.personalRunning)
        try signedIn.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        await model.refreshAccounts()
        XCTAssertFalse(model.needsSetup)
        XCTAssertEqual(model.conversations, [conversation])
        XCTAssertFalse(model.personalRunning, "Reauthorization never starts listeners")
    }

    func testReturningUserIsBlockedForMissingDWSAndIndeterminateAuth() async throws {
        let (model, dir) = try fixture(installed: false, completed: true)
        await model.refreshAccounts(); XCTAssertTrue(model.needsSetup)
        try installMock(in: dir)
        try #"{"authenticated":false,"reason":"keychain_unavailable"}"#.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        await model.refreshAccounts()
        XCTAssertEqual(model.accountCheckState, .indeterminate)
        XCTAssertTrue(model.needsSetup)
    }

    func testLogoutStopsServiceTargetsOneAccountAndKeepsConfiguration() async throws {
        let (model, dir) = try fixture(installed: true, status: signedIn, completed: true)
        await model.refreshAccounts()
        let before = model.config
        model.personalRunning = true
        await model.logout()
        XCTAssertFalse(model.personalRunning); XCTAssertFalse(model.loggingOut)
        XCTAssertNil(model.profile); XCTAssertTrue(model.needsSetup)
        XCTAssertEqual(model.accountCheckState, .signedOut)
        XCTAssertEqual(model.config, before)
        let commands = try String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(commands.map(String.init), ["auth status --readonly --format json", "auth logout --profile corp:user"])
        XCTAssertFalse(commands.contains(where: { $0.hasPrefix("event") }))
    }

    func testLogoutFailureDoesNotPretendToHaveSignedOut() async throws {
        let (model, dir) = try fixture(installed: true, status: signedIn, completed: true)
        await model.refreshAccounts()
        try Data().write(to: dir.appendingPathComponent("logout-fails"))
        model.personalRunning = true
        await model.logout()
        XCTAssertFalse(model.personalRunning)
        XCTAssertTrue(model.accountOK); XCTAssertEqual(model.profile?.id, "corp:user")
        XCTAssertNotNil(model.notice)
    }

    func testFilesystemLogoutTriggersRecheckWithoutWaitingForFallbackTimer() async throws {
        let (model, dir) = try fixture(installed: true, status: signedIn, completed: true)
        let marker = dir.appendingPathComponent("profiles.json")
        try Data("before".utf8).write(to: marker)
        model.begin()
        for _ in 0..<100 where !model.accountOK { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(model.needsSetup)
        let started = Date()
        try #"{"authenticated":false}"#.write(to: dir.appendingPathComponent("status.json"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: marker)
        for _ in 0..<150 where model.accountOK { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.needsSetup)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "The 30-second polling fallback must not be needed")
        XCTAssertFalse(model.loggingIn)
    }
}
