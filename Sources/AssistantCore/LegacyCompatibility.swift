import Foundation

/// Historical identifiers are read only here. New files, bindings and cards
/// use the Assistant namespace; persisted user data is never blindly replaced.
enum LegacyCompatibility {
    static let dataDirectoryNames = [".dws-dashboard", "Library/Application Support/DWS Dashboard"]
    static let cardContextKey = "dashboardProtocol"
    static let cardProtocol = "dws-dashboard-v1"
    static let cardActionPrefix = "dws_dashboard_"
    static let codexScopePrefix = "dashboard-codex-v3-"
    static let retiredCodexScopePrefix = "dashboard-codex-v2-"
    static let engineScopePrefix = "dashboard-"
    static let codexStorageLock = ".dashboard-storage.lock"

    static func previousPrivateWorkspaces(stateDirectory: URL, current: String) -> [String] {
        let data = stateDirectory.deletingLastPathComponent()
        guard stateDirectory.lastPathComponent == "agent-sessions", data.lastPathComponent == ".dws-assistant" else { return [] }
        let actual = URL(fileURLWithPath: current).resolvingSymlinksInPath().standardizedFileURL
        return dataDirectoryNames.compactMap { name in
            let candidate = data.deletingLastPathComponent().appendingPathComponent(name + "/agent-sessions/workspace")
            guard candidate.resolvingSymlinksInPath().standardizedFileURL == actual else { return nil }
            return candidate.path
        }
    }

    static func migrateEngineBinding(to current: String, previousHashes: [String], stateDirectory: URL) throws {
        let connect = stateDirectory.appendingPathComponent("connect", isDirectory: true)
        for hash in Set(previousHashes) {
            for prefix in ["assistant-", engineScopePrefix] {
                let source = connect.appendingPathComponent(prefix + hash, isDirectory: true)
                guard source.lastPathComponent != current, FileManager.default.fileExists(atPath: source.path) else { continue }
                try moveKeepingAlias(from: source, to: connect.appendingPathComponent(current, isDirectory: true))
            }
        }
    }

    static func currentScope(for name: String) -> String? {
        for (old, new) in [(codexScopePrefix, "assistant-codex-v3-"), (engineScopePrefix, "assistant-")] {
            guard name.hasPrefix(old) else { continue }
            let suffix = name.dropFirst(old.count)
            guard suffix.count == 64, suffix.allSatisfy(\.isHexDigit) else { continue }
            return new + suffix
        }
        return nil
    }

    static func migrateStorageNames(in directory: URL) throws {
        let files = FileManager.default
        let bindings = directory.appendingPathComponent("agent-sessions/connect", isDirectory: true)
        if files.fileExists(atPath: bindings.path) {
            for source in try files.contentsOfDirectory(at: bindings, includingPropertiesForKeys: [.isDirectoryKey]) {
                guard let name = currentScope(for: source.lastPathComponent),
                      try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { continue }
                try moveKeepingAlias(from: source, to: bindings.appendingPathComponent(name, isDirectory: true))
            }
        }
        let codex = directory.appendingPathComponent("codex", isDirectory: true)
        let lock = codex.appendingPathComponent(codexStorageLock)
        if files.fileExists(atPath: lock.path) {
            try moveKeepingAlias(from: lock, to: codex.appendingPathComponent(".assistant-storage.lock"))
        }
    }

    static func moveKeepingAlias(from source: URL, to target: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: target.path) {
            guard source.resolvingSymlinksInPath().standardizedFileURL == target.resolvingSymlinksInPath().standardizedFileURL else {
                throw AssistantError.storage("新旧会话数据同时存在，已停止迁移以避免覆盖；请检查本地数据目录")
            }
            return
        }
        let alias = source.deletingLastPathComponent().appendingPathComponent(".dws-assistant-migration-" + UUID().uuidString)
        try files.createSymbolicLink(at: alias, withDestinationURL: target)
        defer { try? files.removeItem(at: alias) }
        try files.moveItem(at: source, to: target)
        do { try files.moveItem(at: alias, to: source) }
        catch {
            if !files.fileExists(atPath: source.path) { try files.moveItem(at: target, to: source) }
            throw error
        }
    }
}

enum AssistantCardProtocol {
    static let contextKey = "assistantProtocol"
    static let version = "dws-assistant-v1"
    static let actionPrefix = "dws_assistant_"

    static func actionPrefix(for context: [String: Any]) -> String? {
        if context[contextKey] != nil {
            guard context[contextKey] as? String == version,
                  context[LegacyCompatibility.cardContextKey] == nil else { return nil }
            return actionPrefix
        }
        guard context[LegacyCompatibility.cardContextKey] as? String == LegacyCompatibility.cardProtocol else { return nil }
        return LegacyCompatibility.cardActionPrefix
    }
}
