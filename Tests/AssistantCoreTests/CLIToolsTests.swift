import XCTest
@testable import AssistantCore

final class CLIToolsTests: XCTestCase {
    private func tool(_ id: String) -> CLITool { CLITool.all.first { $0.id == id }! }
    private func installation(_ path: String, tool: CLITool, version: String = "1.2.3") -> CLIInstallation {
        CLIInstallation(path: path, version: CLIVersion(version), source: .identify(tool: tool, path: path))
    }
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cli-tools-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    private func executable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    func testVersionOutputAndSemanticOrdering() throws {
        for (output, version) in [
            ("codex-cli 0.169.0\n", "0.169.0"),
            ("2.1.263 (Claude Code)", "2.1.263"),
            ("dws version v1.0.66 (abcdef, 2026-10-28T00:00:00Z)", "1.0.66"),
            ("0.58.0-preview.10+build.123", "0.58.0-preview.10+build.123")
        ] { XCTAssertEqual(CLIVersion.parse(output: output)?.text, version) }
        XCTAssertNil(CLIVersion.parse(output: "not signed in"))
        XCTAssertNil(CLIVersion("1.2.3; echo bad"))
        XCTAssertGreaterThan(try XCTUnwrap(CLIVersion("1.10.0")), try XCTUnwrap(CLIVersion("1.9.99")))
        XCTAssertGreaterThan(try XCTUnwrap(CLIVersion("1.0.0-beta.10")), try XCTUnwrap(CLIVersion("1.0.0-beta.2")))
        XCTAssertGreaterThan(try XCTUnwrap(CLIVersion("1.0.0")), try XCTUnwrap(CLIVersion("1.0.0-beta.99")))
        XCTAssertEqual(CLIVersion("1.0.0+abc"), CLIVersion("v1.0.0+def"))
    }

    func testDetectionHonorsOverridesAndOfficialDesktopResolution() async throws {
        let dir = try fixture(), local = dir.appendingPathComponent("local"), appCLI = dir.appendingPathComponent("Qoder.app/Contents/bin/qodercli"), bridge = dir.appendingPathComponent("bridge")
        for url in [local, appCLI, bridge] { try executable(url) }
        let result = try JSONSerialization.data(withJSONObject: [
            "qoder": ["installed": true, "path": appCLI.path],
            "qoderwork": ["installed": false],
            "codex": ["installed": false]
        ])
        let recorder = CLICommandRecorder()
        let service = CLIToolService(run: { spec in
            await recorder.record(spec)
            return CommandResult(status: 0, stdout: String(decoding: result, as: UTF8.self), stderr: "")
        }, resolve: { $0 == "qodercli" ? local.path : nil })
        let paths = await service.detectPaths(overrides: ["codex": local.path, "claude": dir.appendingPathComponent("missing").path], bridge: bridge.path)
        XCTAssertEqual(paths["qoder"], appCLI.path)
        XCTAssertNil(paths["qoderwork"])
        XCTAssertEqual(paths["codex"], local.path)
        XCTAssertNil(paths["claude"])
        let calls = await recorder.commands
        XCTAssertEqual(calls.map(\.arguments), [["--channels"]])
    }

    func testLocalInspectionDeduplicatesSharedCLIAndKeepsBrokenVersionInstalled() async throws {
        let recorder = CLICommandRecorder()
        let service = CLIToolService(run: { spec in
            await recorder.record(spec)
            switch spec.executable {
            case "/tools/shared": return CommandResult(status: 0, stdout: "Qoder CLI 1.1.45", stderr: "")
            default: return CommandResult(status: 1, stdout: "2.3.4", stderr: "cannot load library")
            }
        }, fetch: { _ in XCTFail("Local detection must not query releases"); return Data() })
        let values = await service.inspect(paths: ["qoder": "/tools/shared", "qoderwork": "/tools/shared", "claude": "/tools/broken"], overrides: [:])
        XCTAssertEqual(values["qoder"]?.version?.text, "1.1.45")
        XCTAssertEqual(values["qoderwork"]?.version?.text, "1.1.45")
        XCTAssertNotNil(values["claude"])
        XCTAssertNil(values["claude"]?.version)
        XCTAssertTrue(values["claude"]?.versionError?.contains("cannot load") == true)
        let calls = await recorder.commands
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.arguments == ["--version"] && $0.timeout == 12 && $0.environment?["DWS_NO_UPDATE_CHECK"] == "1" })
    }

    func testCheckOnlyUsesReadOnlyOfficialCommandsAndValidatesRegistryPackage() async throws {
        let recorder = CLICommandRecorder()
        let service = CLIToolService(run: { spec in
            await recorder.record(spec)
            return CommandResult(status: 0, stdout: spec.arguments.first == "upgrade" ? #"{"latest_version":"v1.0.67","needs_upgrade":true}"# : "Already up to date: 1.1.45", stderr: "")
        }, fetch: { url in
            XCTAssertEqual(url.host, "registry.npmjs.org")
            return Data(#"{"name":"@openai/codex","version":"0.170.0"}"#.utf8)
        })
        let dws = tool("dws"), qoder = tool("qoder"), codex = tool("codex")
        let dwsResult = try await service.check(tool: dws, installation: installation("/tools/dws", tool: dws), overrides: [:])
        XCTAssertEqual(dwsResult, .release(CLIVersion("1.0.67")!))
        let qoderResult = try await service.check(tool: qoder, installation: installation("/tools/qodercli", tool: qoder), overrides: [:])
        XCTAssertEqual(qoderResult, .release(CLIVersion("1.1.45")!))
        let npmResult = try await service.check(tool: codex, installation: installation("/prefix/lib/node_modules/@openai/codex/bin/codex", tool: codex), overrides: [:])
        XCTAssertEqual(npmResult, .release(CLIVersion("0.170.0")!))
        let calls = await recorder.commands
        XCTAssertEqual(calls.map(\.arguments), [["upgrade", "--check", "--format", "json"], ["update", "--check"]])
        do {
            _ = try await service.check(tool: tool("gemini"), installation: installation("/tools/gemini", tool: tool("gemini")), overrides: [:])
            XCTFail("A response for another package must not be accepted")
        } catch { /* expected */ }
    }

    func testPlansPreserveInstallOriginAndNeverOverwriteAppBundles() throws {
        let dir = try fixture(), target = dir.appendingPathComponent("node/lib/node_modules/@openai/codex/bin/codex.js"), link = dir.appendingPathComponent("codex")
        try executable(target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let codex = tool("codex"), prefix = dir.appendingPathComponent("node").path
        let installed = installation(link.path, tool: codex)
        XCTAssertEqual(installed.source, .npm(prefix: prefix, package: "@openai/codex"))
        let service = CLIToolService(resolve: { $0 == "npm" ? "/another-node/bin/npm" : nil })
        guard case .command(let spec) = service.plan(tool: codex, installation: installed, overrides: [:]) else { return XCTFail("Missing npm plan") }
        XCTAssertEqual(spec.executable, "/another-node/bin/npm")
        XCTAssertEqual(spec.arguments, ["install", "--global", "--prefix", prefix, "@openai/codex@latest"])
        XCTAssertTrue(spec.environment?["PATH"]?.hasPrefix(prefix + "/bin:") == true)
        XCTAssertEqual(spec.timeout, 600)
        let workbuddy = tool("workbuddy")
        let bundled = installation("/Applications/WorkBuddy.app/Contents/Resources/bin/codebuddy", tool: workbuddy)
        guard case .application(let app) = service.plan(tool: workbuddy, installation: bundled, overrides: [:]) else { return XCTFail("Must use desktop updater") }
        XCTAssertEqual(app.path, "/Applications/WorkBuddy.app")
        guard case .documentation = service.plan(tool: workbuddy, installation: nil, overrides: [:]) else { return XCTFail("Desktop installation needs official guide") }
        guard case .documentation = service.plan(tool: codex, installation: nil, overrides: ["codex": "/missing/custom"]) else { return XCTFail("Must not silently replace a custom command") }
        let brewInstall = installation("/opt/homebrew/Caskroom/codex/1.2.3/codex", tool: codex)
        guard case .command(let brew) = service.plan(tool: codex, installation: brewInstall, overrides: [:]) else { return XCTFail("Missing Homebrew plan") }
        XCTAssertEqual(brew.executable, "/opt/homebrew/bin/brew")
        XCTAssertEqual(brew.arguments, ["upgrade", "--cask", "codex"])
    }

    func testFailedUpdateCheckIsNotReportedAsCurrent() async throws {
        let service = CLIToolService(run: { _ in CommandResult(status: 1, stdout: "Version 99.0.0", stderr: "network failed") })
        do {
            _ = try await service.check(tool: tool("dws"), installation: installation("/tools/dws", tool: tool("dws")), overrides: [:])
            XCTFail("Failed check must remain an error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("network failed")) }
    }

    func testQoderCheckUsesTargetVersionAndRejectsUnrecognizedOutput() async throws {
        let qoder = tool("qoder")
        let installed = installation("/tools/qodercli", tool: qoder, version: "1.1.45")
        let service = CLIToolService(run: { _ in
            CommandResult(status: 0, stdout: "Qoder CLI update (check only)\n\nChecking for updates...\nUpdate available: 1.1.45 -> 1.1.89\n\nRun \"Qoder CLI update\" to install the update.\n", stderr: "")
        })
        let check = try await service.check(tool: qoder, installation: installed, overrides: [:])
        XCTAssertEqual(check, .release(CLIVersion("1.1.89")!))
        for output in ["Current version: 1.1.45", "Update available: 1.1.45 -> unknown", "Update available: 1.1.45 -> 1.1.89; run command"] {
            let invalid = CLIToolService(run: { _ in CommandResult(status: 0, stdout: output, stderr: "") })
            do {
                _ = try await invalid.check(tool: qoder, installation: installed, overrides: [:])
                XCTFail("Unrecognized output must not enable an update")
            } catch { /* expected */ }
        }
    }

    func testInstallableVersionComesFromMatchingOfficialPackageWithoutRunningCommands() async throws {
        let service = CLIToolService(run: { _ in
            XCTFail("Looking up an installable version must not execute an installer")
            return CommandResult(status: 1, stdout: "", stderr: "")
        }, fetch: { url in
            XCTAssertEqual(url.host, "registry.npmjs.org")
            return Data(#"{"name":"@openai/codex","version":"1.2.3"}"#.utf8)
        })
        let release = try await service.availableRelease(tool: tool("codex"))
        XCTAssertEqual(release, .release(CLIVersion("1.2.3")!))
        do {
            _ = try await service.availableRelease(tool: tool("gemini"))
            XCTFail("A different package's version is not an installable version")
        } catch { /* expected */ }
    }

    func testHomebrewCheckUsesFreshOfficialMetadataInsteadOfInstalledCache() async throws {
        let tool = tool("codex")
        let installed = installation("/opt/homebrew/Caskroom/codex/1.2.3/codex", tool: tool)
        let service = CLIToolService(run: { spec in
            XCTAssertEqual(spec.arguments, ["info", "--json=v2", "--cask", "codex"])
            return CommandResult(status: 0, stdout: #"{"casks":[{"tap":"homebrew/cask","version":"1.2.3"}]}"#, stderr: "")
        }, fetch: { url in
            XCTAssertEqual(url.absoluteString, "https://formulae.brew.sh/api/cask/codex.json")
            return Data(#"{"token":"codex","version":"1.3.0"}"#.utf8)
        })
        let value = try await service.check(tool: tool, installation: installed, overrides: [:])
        XCTAssertEqual(value, .release(CLIVersion("1.3.0")!))
    }

    func testUnknownNodeManagerDoesNotUseNativeSelfUpdater() throws {
        let dir = try fixture(), target = dir.appendingPathComponent("pnpm/node_modules/.pnpm/claude/bin/claude"), link = dir.appendingPathComponent("claude")
        try executable(target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let claude = tool("claude")
        let service = CLIToolService(resolve: { _ in "/other/npm" })
        guard case .documentation = service.plan(tool: claude, installation: installation(link.path, tool: claude), overrides: [:]) else {
            return XCTFail("An unknown manager must not be silently replaced")
        }
    }
}

private actor CLICommandRecorder {
    private(set) var commands: [CommandSpec] = []
    func record(_ spec: CommandSpec) { commands.append(spec) }
}
