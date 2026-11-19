import XCTest
@testable import AssistantCore
@testable import DWSAssistant

@MainActor
final class CLIToolsModelTests: XCTestCase {
    private func fixture() throws -> (URL, String) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-model-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("qodercli")
        try "#!/bin/sh\nexit 0\n".write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return (directory, path.path)
    }

    func testCheckFailureKeepsInstallationAndDoesNotMutateTools() async throws {
        let (_, path) = try fixture()
        let fake = FakeCLIUpdate()
        let model = CLIToolsModel(service: CLIToolService(run: { await fake.run($0) }, fetch: { try mockRelease($0) }, resolve: { $0 == "qodercli" ? path : nil }))
        await model.refresh(overrides: [:], bridge: nil, checkUpdates: true)
        XCTAssertEqual(model.installations["qoder"]?.version?.text, "1.0.0")
        XCTAssertEqual(model.installations["qoderwork"]?.version?.text, "1.0.0")
        XCTAssertNil(model.updates["qoder"])
        XCTAssertNotNil(model.errors["qoder"])
        XCTAssertEqual(model.errors["qoder"], model.errors["qoderwork"])
        XCTAssertFalse(model.isBusy)
        let calls = await fake.calls
        XCTAssertEqual(calls, [["--version"], ["update", "--check"]])
    }

    func testUpdatingRefreshesBothChannelsAndRejectsDuplicateOperation() async throws {
        let (_, path) = try fixture()
        let fake = FakeCLIUpdate()
        let model = CLIToolsModel(service: CLIToolService(run: { await fake.run($0) }, fetch: { try mockRelease($0) }, resolve: { $0 == "qodercli" ? path : nil }))
        await model.refresh(overrides: [:], bridge: nil)
        let tool = CLITool.all.first { $0.id == "qoder" }!
        var finished = 0
        guard case .command(let command) = model.plan(for: tool, overrides: [:]) else { return XCTFail("Missing update command") }
        model.start(tool: tool, command: command, overrides: [:], bridge: nil) { finished += 1 }
        model.start(tool: tool, command: command, overrides: [:], bridge: nil) { finished += 100 }
        XCTAssertTrue(model.isChangingTools)
        await model.waitForOperation()
        XCTAssertFalse(model.isChangingTools)
        XCTAssertFalse(model.isBusy)
        XCTAssertEqual(finished, 1)
        XCTAssertEqual(model.installations["qoder"]?.version?.text, "1.1.0")
        XCTAssertEqual(model.installations["qoderwork"]?.version?.text, "1.1.0")
        XCTAssertNil(model.errors["qoder"])
        XCTAssertEqual(model.availableVersion(for: CLITool.all.first { $0.id == "codex" }!)?.text, "1.2.0", "Updating one tool must preserve other tools' installable versions")
        let calls = await fake.calls
        XCTAssertEqual(calls, [["--version"], ["update"], ["--version"]])
    }

    func testFailedInstallRemainsMissingWithVisibleError() async throws {
        let fake = FakeCLIUpdate()
        let model = CLIToolsModel(service: CLIToolService(run: { await fake.run($0) }, resolve: { $0 == "npm" ? "/mock/npm" : nil }))
        let tool = CLITool.all.first { $0.id == "codex" }!
        guard case .command(let command) = model.plan(for: tool, overrides: [:]) else { return XCTFail("Missing install command") }
        model.start(tool: tool, command: command, overrides: [:], bridge: nil) {}
        await model.waitForOperation()
        XCTAssertNil(model.installations["codex"])
        XCTAssertTrue(model.errors["codex"]?.contains("permission denied") == true)
        XCTAssertFalse(model.isBusy)
    }

    func testUpdateDoesNotDowngradeNewerNpmInstallationBeforeExplicitCheck() async throws {
        let (directory, _) = try fixture()
        let binary = directory.appendingPathComponent("prefix/lib/node_modules/@openai/codex/bin/codex")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let service = CLIToolService(run: { spec in
            XCTAssertEqual(spec.arguments, ["--version"], "No mutation is allowed when the stable release is older")
            return CommandResult(status: 0, stdout: "1.3.0-preview.1", stderr: "")
        }, fetch: { try mockRelease($0) },
                                    resolve: { $0 == "codex" ? binary.path : $0 == "npm" ? "/mock/npm" : nil })
        let model = CLIToolsModel(service: service)
        await model.refresh(overrides: [:], bridge: nil)
        let tool = CLITool.all.first { $0.id == "codex" }!
        guard case .command(let command) = model.plan(for: tool, overrides: [:]) else { return XCTFail("Missing update plan") }
        model.start(tool: tool, command: command, overrides: [:], bridge: nil) {}
        await model.waitForOperation()
        XCTAssertEqual(model.updates["codex"], .release(CLIVersion("1.2.0")!))
        XCTAssertNil(model.errors["codex"])
    }

    func testMissingToolsLoadInstallableVersionsAndDeduplicateSharedPackages() async throws {
        let releases = CLIReleaseRecorder()
        let model = CLIToolsModel(service: CLIToolService(run: { _ in
            XCTFail("An absent tool needs a release lookup, not an executable")
            return CommandResult(status: 1, stdout: "", stderr: "")
        }, fetch: { try await releases.fetch($0) }, resolve: { _ in nil }))
        await model.refresh(overrides: [:], bridge: nil)
        for tool in CLITool.all {
            XCTAssertNil(model.installations[tool.id])
            XCTAssertEqual(model.availableVersion(for: tool)?.text, "1.2.0")
            XCTAssertNil(model.updateVersion(for: tool), "An uninstalled tool must offer Install, not Update")
        }
        let requests = await releases.requests
        XCTAssertEqual(requests.count, Set(CLITool.all.map(\.npmPackage)).count)
        XCTAssertEqual(Set(requests).count, requests.count)
    }

    func testUpdateIsOfferedOnlyForConfirmedNewerInstalledVersion() async throws {
        let (_, path) = try fixture()
        let codex = CLITool.all.first { $0.id == "codex" }!
        for (installed, available, offered) in [("1.1.0", "1.2.0", true), ("1.2.0", "1.2.0", false), ("1.3.0-preview.1", "1.2.0", false), ("unknown", "1.2.0", false)] {
            let model = CLIToolsModel(service: CLIToolService(run: { _ in CommandResult(status: 0, stdout: installed, stderr: "") },
                fetch: { try mockRelease($0, version: available) }, resolve: { $0 == "codex" ? path : nil }))
            await model.refresh(overrides: [:], bridge: nil)
            XCTAssertNil(model.updateVersion(for: codex), "Detection alone cannot confirm an update")
            await model.refresh(overrides: [:], bridge: nil, checkUpdates: true)
            XCTAssertEqual(model.updateVersion(for: codex) != nil, offered)
        }
    }

    func testFailedRecheckRemovesPreviouslyOfferedUpdate() async throws {
        let (_, path) = try fixture()
        let releases = CLIReleaseRecorder()
        let codex = CLITool.all.first { $0.id == "codex" }!
        let model = CLIToolsModel(service: CLIToolService(run: { _ in CommandResult(status: 0, stdout: "1.1.0", stderr: "") },
            fetch: { try await releases.fetch($0) }, resolve: { $0 == "codex" ? path : nil }))
        await model.refresh(overrides: [:], bridge: nil, checkUpdates: true)
        XCTAssertNotNil(model.updateVersion(for: codex))
        await releases.fail()
        await model.refresh(overrides: [:], bridge: nil, checkUpdates: true)
        XCTAssertNil(model.updateVersion(for: codex))
        XCTAssertNotNil(model.errors[codex.id])
    }
}

private func mockRelease(_ url: URL, version: String = "1.2.0") throws -> Data {
    let package = String(url.absoluteString.dropFirst("https://registry.npmjs.org/".count).dropLast("/latest".count)).removingPercentEncoding!
    return try JSONSerialization.data(withJSONObject: ["name": package, "version": version])
}

private actor CLIReleaseRecorder {
    private(set) var requests: [URL] = []
    private var failing = false
    func fail() { failing = true }
    func fetch(_ url: URL) throws -> Data {
        requests.append(url)
        if failing { throw URLError(.notConnectedToInternet) }
        return try mockRelease(url)
    }
}

private actor FakeCLIUpdate {
    private(set) var calls: [[String]] = []
    private var version = "1.0.0"
    func run(_ spec: CommandSpec) -> CommandResult {
        calls.append(spec.arguments)
        switch spec.arguments {
        case ["--version"]: return CommandResult(status: 0, stdout: version, stderr: "")
        case ["update"]: version = "1.1.0"; return CommandResult(status: 0, stdout: "Updated", stderr: "")
        case ["update", "--check"]: return CommandResult(status: 1, stdout: "", stderr: "network failed")
        default: return CommandResult(status: 1, stdout: "", stderr: "permission denied")
        }
    }
}
