import XCTest
@testable import DashboardCore

final class DirectorySettingsTests: XCTestCase {
    func testEmptySelectionPersistsAndCanRemoveLastDirectory() throws {
        var settings = AgentSettings()
        XCTAssertTrue(settings.authorizedDirectories.isEmpty)
        XCTAssertNoThrow(try Validation.agent(settings))
        settings.authorizedDirectories = ["/tmp", "/tmp"]
        XCTAssertEqual(settings.authorizedDirectories, ["/tmp"])
        settings.authorizedDirectories.removeAll()
        XCTAssertEqual(settings.workdir, "")
        XCTAssertTrue(settings.additionalDirectories.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testLegacyImplicitHomeIsRemovedButExplicitNewSelectionSurvives() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let legacy: [String: Any] = ["engine": "codex", "model": "", "workdir": home, "additionalDirectories": ["/tmp"], "permission": "restricted", "timeout": 120]
        let migrated = try JSONDecoder().decode(AgentSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(migrated.authorizedDirectories, ["/tmp"])
        var chosen = AgentSettings(); chosen.authorizedDirectories = [home]
        XCTAssertEqual(try JSONDecoder().decode(AgentSettings.self, from: JSONEncoder().encode(chosen)).authorizedDirectories, [home])
    }

    func testEmptySelectionLaunchesInAppWorkspaceWithoutHomeGrant() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-empty-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = AgentSettings()
        let spec = try Commands.officialAgent(settings, prompt: "test", route: "route", bridgePath: "/bin/echo", stateDirectory: root.path, config: DashboardConfig())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(spec.stdin!.utf8)) as? [String: Any])
        XCTAssertEqual(spec.directory, root.appendingPathComponent("workspace").path)
        XCTAssertEqual(payload["workdir"] as? String, spec.directory)
        XCTAssertEqual(payload["additional_directories"] as? [String], [])
        XCTAssertEqual(payload["authorized_directories"] as? [String], [], "The internal fallback workspace is not a user authorization")
        XCTAssertFalse(payload["full_permission"] as? Bool ?? true)
        XCTAssertTrue(settings.authorizedDirectories.isEmpty)
        settings.engine = .gemini
        var config = DashboardConfig(); config.executablePaths["gemini"] = "/bin/echo"
        let gemini = try Commands.officialAgent(settings, prompt: "test", route: "route", bridgePath: "/bin/echo", stateDirectory: root.path, config: config)
        XCTAssertEqual(gemini.directory, spec.directory)
        XCTAssertFalse(gemini.arguments.contains("--include-directories"))
    }

    func testAuthorizedProjectsReachAdapterWithoutEnablingWrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-projects-\(UUID())")
        let project = root.appendingPathComponent("project"), extra = root.appendingPathComponent("shared")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        var settings = AgentSettings(); settings.authorizedDirectories = [project.path, extra.path]
        let spec = try Commands.officialAgent(settings, prompt: "查找打包脚本", route: "route", bridgePath: "/bin/echo", stateDirectory: root.appendingPathComponent("state").path, config: DashboardConfig())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(spec.stdin!.utf8)) as? [String: Any])
        XCTAssertEqual(payload["authorized_directories"] as? [String], [project.path, extra.path])
        XCTAssertEqual(payload["workdir"] as? String, project.path)
        XCTAssertEqual(payload["additional_directories"] as? [String], [extra.path])
        XCTAssertEqual(payload["full_permission"] as? Bool, false)
    }

    func testPathAbbreviationOnlyMatchesCurrentHomeBoundary() {
        XCTAssertEqual(DashboardPaths.display("/Users/me/.dws-dashboard", home: "/Users/me"), "~/.dws-dashboard")
        XCTAssertEqual(DashboardPaths.display("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(DashboardPaths.display("/Users/meeting/file", home: "/Users/me"), "/Users/meeting/file")
        XCTAssertEqual(DashboardPaths.display("/opt/homebrew/bin", home: "/Users/me"), "/opt/homebrew/bin")
    }
}
