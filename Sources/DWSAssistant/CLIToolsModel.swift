import Foundation
import Combine
import AssistantCore

@MainActor
final class CLIToolsModel: ObservableObject {
    enum Activity: Equatable { case detecting, checking, installing(String), updating(String) }
    @Published private(set) var installations: [String: CLIInstallation] = [:]
    @Published private(set) var updates: [String: CLIUpdateCheck] = [:]
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var output: [String: String] = [:]
    @Published private(set) var activity: Activity?
    @Published private(set) var detectedAt: Date?
    @Published private(set) var checkedAt: Date?
    private let service: CLIToolService
    private var operation: Task<Void, Never>?

    init(service: CLIToolService = CLIToolService()) { self.service = service }
    var isBusy: Bool { activity != nil }
    var isChangingTools: Bool { operation != nil }

    func availableVersion(for tool: CLITool) -> CLIVersion? {
        guard case .release(let version) = updates[tool.id] else { return nil }
        return version
    }

    func updateVersion(for tool: CLITool) -> CLIVersion? {
        guard let current = installations[tool.id]?.version,
              let available = availableVersion(for: tool), available > current else { return nil }
        return available
    }

    func refresh(overrides: [String: String], bridge: String?, checkUpdates: Bool = false) async {
        guard !isBusy else { return }
        activity = .detecting
        defer { activity = nil }
        errors.removeAll()
        await detect(overrides: overrides, bridge: bridge)
        guard !Task.isCancelled else { return }
        if checkUpdates { activity = .checking }
        // Missing tools also need a version before the user chooses to install.
        // Shared channels query the same installation or package only once.
        let groups = Dictionary(grouping: CLITool.all.filter { checkUpdates || installations[$0.id] == nil }, by: {
            installations[$0.id].map { "installed:" + $0.path } ?? "available:" + $0.npmPackage
        })
        await withTaskGroup(of: ([String], Result<CLIUpdateCheck, Error>).self) { group in
            for tools in groups.values {
                let tool = tools[0], installation = installations[tools[0].id]
                group.addTask { [service] in
                    do {
                        let check: CLIUpdateCheck
                        if let installation { check = try await service.check(tool: tool, installation: installation, overrides: overrides) }
                        else { check = try await service.availableRelease(tool: tool) }
                        return (tools.map(\.id), .success(check))
                    }
                    catch { return (tools.map(\.id), .failure(error)) }
                }
            }
            for await (ids, result) in group {
                guard !Task.isCancelled else { continue }
                for id in ids {
                    switch result {
                    case .success(let check): updates[id] = check
                    case .failure(let error):
                        updates[id] = nil
                        errors[id] = Redaction.clean(error.localizedDescription)
                    }
                }
            }
        }
        if !Task.isCancelled, checkUpdates { checkedAt = Date() }
    }

    private func detect(overrides: [String: String], bridge: String?) async {
        let paths = await service.detectPaths(overrides: overrides, bridge: bridge)
        let detected = await service.inspect(paths: paths, overrides: overrides)
        guard !Task.isCancelled else { return }
        updates = updates.filter { id, _ in
            installations[id]?.path == detected[id]?.path && installations[id]?.source == detected[id]?.source
        }
        installations = detected; detectedAt = Date()
    }

    func plan(for tool: CLITool, overrides: [String: String]) -> CLIManagementPlan {
        service.plan(tool: tool, installation: installations[tool.id], overrides: overrides)
    }

    func start(tool: CLITool, command: CommandSpec, overrides: [String: String], bridge: String?,
               didFinish: @escaping @MainActor () -> Void) {
        guard !isBusy else { return }
        let previous = installations[tool.id]
        activity = previous == nil ? .installing(tool.id) : .updating(tool.id)
        errors.removeAll(); output[tool.id] = nil
        operation = Task {
            defer { operation = nil; activity = nil; didFinish() }
            do {
                if let previous, case .npm = previous.source, let current = previous.version,
                   case .release(let latest) = try await service.check(tool: tool, installation: previous, overrides: overrides), latest <= current {
                    // npm install @latest also permits downgrades. Recheck at
                    // execution time, including when Update is clicked before
                    // the user has run the explicit update check.
                    for (id, installed) in installations where installed.path == previous.path { updates[id] = .release(latest) }
                    output[tool.id] = "当前版本无需更新，未执行安装命令。"
                    return
                }
                let result = try await service.execute(command)
                output[tool.id] = String(Redaction.clean(result.stdout + "\n" + result.stderr).suffix(16_384))
                checkedAt = nil
                await detect(overrides: overrides, bridge: bridge)
                guard let current = installations[tool.id] else {
                    errors[tool.id] = "命令已完成，但尚未找到工具；请重新检测或查看官方安装说明。"
                    return
                }
                if let error = current.versionError {
                    errors[tool.id] = error
                } else if previous?.version == current.version {
                    output[tool.id, default: ""] += "\n更新命令已完成，版本未变化。"
                }
            } catch {
                // An installer can fail after changing files. Refresh local
                // state even on failure, while keeping the failure visible.
                errors[tool.id] = Redaction.clean(error.localizedDescription)
                checkedAt = nil
                await detect(overrides: overrides, bridge: bridge)
            }
        }
    }

    func waitForOperation() async { await operation?.value }

    func loadPreview(paths: [String: String]) {
        guard detectedAt == nil else { return }
        let versions = ["dws": "1.0.66", "codex": "0.169.0", "claude": "2.1.263", "qoder": "1.1.45", "qoderwork": "1.1.45", "opencode": "1.18.29", "gemini": "0.58.0"]
        installations = Dictionary(uniqueKeysWithValues: CLITool.all.compactMap { tool in
            guard let path = paths[tool.id], path != "未找到" else { return nil }
            return (tool.id, CLIInstallation(path: path, version: versions[tool.id].flatMap(CLIVersion.init), source: .identify(tool: tool, path: path)))
        })
        detectedAt = Date()
    }
}

extension AssistantModel {
    func refreshCLITools(checkUpdates: Bool = false) async {
        guard !preview else { cliTools.loadPreview(paths: detectedPaths); return }
        await cliTools.refresh(overrides: config.executablePaths, bridge: nativeBridgePath(), checkUpdates: checkUpdates)
        detectExecutables()
    }

    func manageCLITool(_ tool: CLITool, command: CommandSpec) {
        guard !preview, !cliToolInUse(tool) else { return }
        cliTools.start(tool: tool, command: command, overrides: config.executablePaths, bridge: nativeBridgePath()) { [weak self] in
            self?.detectExecutables()
        }
    }

    func cliToolInUse(_ tool: CLITool) -> Bool {
        if tool.id == "dws" { return personalRunning || stopping || loggingIn || loggingOut }
        return (personalRunning || stopping || !replyStates.isEmpty) && config.conversations.contains {
            $0.listen && $0.autoReply && $0.agent.engine.executable == tool.executable
        }
    }
}
