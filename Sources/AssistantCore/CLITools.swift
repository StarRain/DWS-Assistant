import Foundation

/// The fixed CLI dependencies of the supported channels. Custom agents supply
/// their own command and therefore have no shared installation to manage.
public struct CLITool: Identifiable, Hashable {
    public let id: String
    public var engine: Engine? { Engine(rawValue: id) }
    public var executable: String { engine?.executable ?? "dws" }
    public var title: String { engine?.title ?? "钉钉 DWS" }
    public static let all = [CLITool(id: "dws")] + Engine.installedCLIEngines.map { CLITool(id: $0.rawValue) }

    public var npmPackage: String {
        switch id {
        case "codex": return "@openai/codex"
        case "claude": return "@anthropic-ai/claude-code"
        case "qoder", "qoderwork": return "@qoder-ai/qodercli"
        case "opencode": return "opencode-ai"
        case "workbuddy", "codebuddy": return "@tencent-ai/codebuddy-code"
        case "gemini": return "@google/gemini-cli"
        case "pi": return "@earendil-works/pi-coding-agent"
        default: return "dingtalk-workspace-cli"
        }
    }

    public var documentationURL: URL {
        let address: String
        switch id {
        case "codex": address = "https://github.com/openai/codex#installation"
        case "claude": address = "https://code.claude.com/docs/en/setup"
        case "qoder": address = "https://docs.qoder.com/cli/installation"
        case "qoderwork": address = "https://qoder.com"
        case "opencode": address = "https://opencode.ai/docs/"
        case "workbuddy": address = "https://www.codebuddy.cn/work/"
        case "codebuddy": address = "https://www.codebuddy.ai/docs/cli/quickstart"
        case "gemini": address = "https://geminicli.com/docs/get-started/installation/"
        case "pi": address = "https://github.com/earendil-works/pi"
        default: address = "https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli#installation"
        }
        return URL(string: address)!
    }

    public var isDesktopChannel: Bool { id == "qoderwork" || id == "workbuddy" }
}

public struct CLIVersion: Comparable, Equatable {
    public let text: String
    private let numbers: [Int]
    private let prerelease: [String]

    public init?(_ source: String) {
        let pattern = #"^v?(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$"#
        guard let match = source.range(of: pattern, options: .regularExpression) else { return nil }
        text = String(source[match]).replacingOccurrences(of: #"^v"#, with: "", options: .regularExpression)
        let base = text.components(separatedBy: "+")[0].split(separator: "-", maxSplits: 1)
        let components = base[0].split(separator: ".").compactMap { Int($0) }
        guard components.count == 3 else { return nil }
        numbers = components
        prerelease = base.count > 1 ? base[1].split(separator: ".").map(String.init) : []
    }

    public static func parse(output: String) -> CLIVersion? {
        let pattern = #"(?<![\w.])v?\d+\.\d+\.\d+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z.-]+)?(?![\w.])"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return CLIVersion(String(output[range]))
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}

public enum CLIInstallSource: Equatable {
    case npm(prefix: String, package: String)
    case homebrew(prefix: String, package: String, cask: Bool)
    case application(URL)
    case standalone

    public static func identify(tool: CLITool, path: String) -> Self {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        for candidate in [path, resolved] {
            if let range = candidate.range(of: ".app/Contents/") {
                return .application(URL(fileURLWithPath: String(candidate[..<range.lowerBound]) + ".app"))
            }
        }
        // A local node_modules directory, pnpm store or Bun global directory is
        // not an npm global prefix. Never replace it through another manager.
        let packages = [tool.npmPackage] + (tool.id == "pi" ? ["@mariozechner/pi-coding-agent"] : [])
        for package in packages {
            if let range = resolved.range(of: "/lib/node_modules/" + package + "/") {
                return .npm(prefix: String(resolved[..<range.lowerBound]), package: package)
            }
        }
        for (directory, cask) in [("/Cellar/", false), ("/Caskroom/", true)] {
            if let range = resolved.range(of: directory) {
                let package = String(resolved[range.upperBound...].split(separator: "/").first ?? "")
                if !package.isEmpty { return .homebrew(prefix: String(resolved[..<range.lowerBound]), package: package, cask: cask) }
            }
        }
        return .standalone
    }
}

public struct CLIInstallation {
    public let path: String
    public let version: CLIVersion?
    public let versionError: String?
    public let source: CLIInstallSource
    public init(path: String, version: CLIVersion?, versionError: String? = nil, source: CLIInstallSource) {
        self.path = path; self.version = version; self.versionError = versionError; self.source = source
    }
}

public enum CLIUpdateCheck: Equatable {
    case release(CLIVersion)
    case application
    case externalPackageManager
}

public enum CLIManagementPlan {
    case command(CommandSpec)
    case documentation(URL)
    case application(URL)
}

public struct CLIToolService {
    public typealias Run = (CommandSpec) async throws -> CommandResult
    public typealias Fetch = (URL) async throws -> Data
    private let run: Run
    private let fetch: Fetch
    private let resolve: (String) -> String?

    public init(run: @escaping Run = ProcessRunner.run,
                fetch: @escaping Fetch = CLIToolService.fetchRelease,
                resolve: @escaping (String) -> String? = { try? Executables.resolve($0) }) {
        self.run = run; self.fetch = fetch; self.resolve = resolve
    }

    public static func fetchRelease(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), data.count <= 1_048_576 else {
            throw AssistantError.command("无法读取官方版本信息")
        }
        return data
    }

    public func detectPaths(overrides: [String: String], bridge: String?) async -> [String: String] {
        var paths = Dictionary(uniqueKeysWithValues: CLITool.all.compactMap { tool -> (String, String)? in
            let path = overrides[tool.executable].flatMap { $0.isEmpty ? nil : $0 } ?? resolve(tool.executable)
            guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
            return (tool.id, path)
        })
        if let bridge, FileManager.default.isExecutableFile(atPath: bridge),
           let result = try? await run(command(bridge, ["--channels"], overrides: overrides, timeout: 5)), result.status == 0,
           let rows = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: [String: Any]] {
            for tool in CLITool.all {
                guard let engine = tool.engine, engine.usesBridge, overrides[tool.executable, default: ""].isEmpty,
                      let row = rows[engine.channel] else { continue }
                if row["installed"] as? Bool == true, let path = row["path"] as? String, FileManager.default.isExecutableFile(atPath: path) {
                    paths[tool.id] = path
                } else { paths.removeValue(forKey: tool.id) }
            }
        }
        return paths
    }

    public func inspect(paths: [String: String], overrides: [String: String]) async -> [String: CLIInstallation] {
        // Qoder/QoderWork and CodeBuddy/WorkBuddy can point at the same binary.
        let unique = Set(paths.values)
        let versions = await withTaskGroup(of: (String, CLIVersion?, String?).self) { group in
            for path in unique {
                group.addTask {
                    do {
                        let result = try await run(command(path, ["--version"], overrides: overrides, timeout: 12)).checked()
                        guard let version = CLIVersion.parse(output: result.stdout) ?? CLIVersion.parse(output: result.stderr) else {
                            return (path, nil, "工具未返回可识别的版本号")
                        }
                        return (path, version, nil)
                    } catch { return (path, nil, Redaction.clean(error.localizedDescription)) }
                }
            }
            var values: [String: (CLIVersion?, String?)] = [:]
            for await (path, version, error) in group { values[path] = (version, error) }
            return values
        }
        return Dictionary(uniqueKeysWithValues: CLITool.all.compactMap { tool in
            guard let path = paths[tool.id] else { return nil }
            return (tool.id, CLIInstallation(path: path, version: versions[path]?.0, versionError: versions[path]?.1,
                                              source: .identify(tool: tool, path: path)))
        })
    }

    public func check(tool: CLITool, installation: CLIInstallation, overrides: [String: String]) async throws -> CLIUpdateCheck {
        if case .application = installation.source { return .application }
        if tool.id == "dws" {
            let result = try await run(command(installation.path, ["upgrade", "--check", "--format", "json"], overrides: overrides)).checked()
            let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            guard let text = json?["latest_version"] as? String, let version = CLIVersion(text) else {
                throw AssistantError.command("无法读取官方版本信息")
            }
            return .release(version)
        }
        if case .homebrew(let prefix, let package, let cask) = installation.source {
            let brew = prefix + "/bin/brew"
            let result = try await run(command(brew, ["info", "--json=v2", cask ? "--cask" : "--formula", package], overrides: overrides)).checked()
            let json = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any]
            let row = (json?[cask ? "casks" : "formulae"] as? [[String: Any]])?.first
            // brew info may read old local tap/API metadata. Query Homebrew's
            // official API for a fresh release instead of calling it current.
            guard row?["tap"] as? String == (cask ? "homebrew/cask" : "homebrew/core") else { return .externalPackageManager }
            let token = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))!
            let data = try await fetch(URL(string: "https://formulae.brew.sh/api/\(cask ? "cask" : "formula")/\(token).json")!)
            let release = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let value = cask ? release?["version"] as? String : (release?["versions"] as? [String: Any])?["stable"] as? String
            guard let value, let version = CLIVersion(value) else { throw AssistantError.command("无法读取官方版本信息") }
            return .release(version)
        }
        if tool.executable == "qodercli", case .standalone = installation.source {
            let result = try await run(command(installation.path, ["update", "--check"], overrides: overrides)).checked()
            let output = Redaction.clean(result.stdout + "\n" + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            // Only accept an explicit target version from the official check.
            // Its output can contain both the installed and available version.
            for line in output.components(separatedBy: .newlines) {
                if line.hasPrefix("Update available:"), let arrow = line.range(of: "->"),
                   let version = CLIVersion(String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)) {
                    return .release(version)
                }
                if line.hasPrefix("Already up to date:"),
                   let version = CLIVersion(String(line.dropFirst("Already up to date:".count)).trimmingCharacters(in: .whitespaces)) {
                    return .release(version)
                }
            }
            throw AssistantError.command("无法读取官方版本信息")
        }
        let package: String
        if case .npm(_, let installedPackage) = installation.source { package = installedPackage }
        else { package = tool.npmPackage }
        return .release(try await registryVersion(package: package))
    }

    public func availableRelease(tool: CLITool) async throws -> CLIUpdateCheck {
        .release(try await registryVersion(package: tool.npmPackage))
    }

    private func registryVersion(package: String) async throws -> CLIVersion {
        let encoded = package.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/")))!
        let data = try await fetch(URL(string: "https://registry.npmjs.org/\(encoded)/latest")!)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["name"] as? String == package, let value = json?["version"] as? String, let version = CLIVersion(value) else {
            throw AssistantError.command("无法读取官方版本信息")
        }
        return version
    }

    public func plan(tool: CLITool, installation: CLIInstallation?, overrides: [String: String]) -> CLIManagementPlan {
        guard let installed = installation else {
            // These channels are distributed with their desktop host by DWS.
            guard !tool.isDesktopChannel, overrides[tool.executable, default: ""].isEmpty,
                  let npm = resolve("npm") else { return .documentation(tool.documentationURL) }
            return .command(command(npm, ["install", "--global", tool.npmPackage + "@latest"], overrides: overrides, timeout: 600))
        }
        switch installed.source {
        case .application(let app): return .application(app)
        case .npm(let prefix, let package):
            let local = prefix + "/bin/npm"
            guard let npm = FileManager.default.isExecutableFile(atPath: local) ? local : resolve("npm") else { return .documentation(tool.documentationURL) }
            // Explicit prefix preserves the detected installation when multiple
            // Node distributions or a different npm global prefix are present.
            var spec = command(npm, ["install", "--global", "--prefix", prefix, package + "@latest"], overrides: overrides, timeout: 600)
            let path = prefix + "/bin:" + (spec.environment?["PATH"] ?? "")
            spec.environment?["PATH"] = path
            return .command(spec)
        case .homebrew(let prefix, let package, let cask):
            return .command(command(prefix + "/bin/brew", ["upgrade", cask ? "--cask" : "--formula", package], overrides: overrides, timeout: 600))
        case .standalone:
            // Respect custom launchers and unknown package-manager layouts.
            let resolved = URL(fileURLWithPath: installed.path).resolvingSymlinksInPath().path
            guard overrides[tool.executable, default: ""].isEmpty, !resolved.contains("node_modules/"), !resolved.contains("/.bun/") else {
                return .documentation(tool.documentationURL)
            }
            let args: [String]
            switch tool.executable {
            case "dws": args = ["upgrade", "--yes"]
            case "claude", "qodercli", "codebuddy": args = ["update"]
            case "opencode": args = ["upgrade"]
            default: return .documentation(tool.documentationURL)
            }
            return .command(command(installed.path, args, overrides: overrides, timeout: 600))
        }
    }

    public func execute(_ spec: CommandSpec) async throws -> CommandResult { try await run(spec).checked() }

    private func command(_ executable: String, _ arguments: [String], overrides: [String: String], timeout: TimeInterval = 30) -> CommandSpec {
        var environment = Executables.environment(overrides: overrides)
        environment["DWS_NO_UPDATE_CHECK"] = "1" // Installation detection stays local.
        return CommandSpec(executable: executable, arguments: arguments, directory: FileManager.default.temporaryDirectory.path,
                           environment: environment, timeout: timeout)
    }
}
