import Foundation
import Darwin

/// Observes filesystem metadata only; never reads token contents. DWS uses
/// atomic replacement, so both containing directories and file inodes matter.
@MainActor public final class DWSLoginWatcher {
    public static var defaultDirectories: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [home.appendingPathComponent(".dws"), home.appendingPathComponent("Library/Application Support/dws-cli")]
    }
    private let directories: [URL]
    private let onChange: () -> Void
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var inodes: [String: UInt64] = [:]
    private var snapshot: [String: String] = [:]
    private var pending: Task<Void, Never>?
    private var active = false

    public init(directories: [URL], onChange: @escaping () -> Void) {
        self.directories = directories.map(\.standardizedFileURL)
        self.onChange = onChange
    }

    public func start() {
        guard !active else { return }
        active = true
        reconcile(notify: false)
    }

    public func stop() {
        active = false; pending?.cancel(); pending = nil
        for source in sources.values { source.cancel() }
        sources.removeAll(); inodes.removeAll()
    }

    private func enqueue() {
        guard active else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)); try Task.checkCancellation() }
            catch { return }
            self?.reconcile(notify: true)
        }
    }

    private func reconcile(notify: Bool) {
        guard active else { return }
        let files = FileManager.default
        var wanted = Set<String>(), next: [String: String] = [:]
        for root in directories {
            // Watching the nearest existing parent also detects first login,
            // deleting the whole directory, and replacing it with a new inode.
            var parent = root.deletingLastPathComponent()
            while !files.fileExists(atPath: parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
            wanted.insert(parent.path)
            guard let attrs = try? files.attributesOfItem(atPath: root.path) else { continue }
            wanted.insert(root.path)
            next[root.path] = "directory:\(attrs[.systemFileNumber] ?? "")"
            for item in (try? files.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                let name = item.lastPathComponent
                guard name == "profiles.json" || name == "token.json" || (name.hasPrefix("auth-token") && name.hasSuffix(".enc")) else { continue }
                guard let value = try? files.attributesOfItem(atPath: item.path) else { continue }
                let modified = (value[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
                next[item.path] = "\(value[.systemFileNumber] ?? ""):\(value[.size] ?? ""):\(modified)"
                wanted.insert(item.path)
            }
        }
        for path in Array(sources.keys) where !wanted.contains(path) {
            sources.removeValue(forKey: path)?.cancel(); inodes.removeValue(forKey: path)
        }
        for path in wanted {
            guard let attrs = try? files.attributesOfItem(atPath: path), let inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            if sources[path] != nil && inodes[path] == inode { continue }
            sources.removeValue(forKey: path)?.cancel()
            let descriptor = Darwin.open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .delete, .rename, .attrib, .extend, .revoke], queue: .main)
            source.setEventHandler { [weak self] in Task { @MainActor in self?.enqueue() } }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources[path] = source; inodes[path] = inode; source.resume()
        }
        let changed = next != snapshot
        snapshot = next
        if notify && changed { onChange() }
    }

    deinit {
        pending?.cancel()
        for source in sources.values { source.cancel() }
    }
}
