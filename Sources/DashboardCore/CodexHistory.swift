import Foundation

/// Reads the assistant's persisted history without starting Codex or taking a writer lock.
public enum CodexHistory {
    public struct Entry: Identifiable, Sendable {
        public enum Kind: String, Sendable { case user, assistant, execution }
        public let id: String
        public let kind: Kind
        public let timestamp: String
        public let text: String
        public let detail: String
    }

    public struct Snapshot: Sendable {
        public let entries: [Entry]
        public let hasEarlier: Bool
    }

    public static func home(stateDirectory: URL) -> URL {
        let data = stateDirectory.lastPathComponent == "agent-sessions" ? stateDirectory.deletingLastPathComponent() : stateDirectory
        return data.appendingPathComponent("codex", isDirectory: true)
    }

    public static func scope(route: String) -> String { "dashboard-codex-v3-" + Digest.sha256(route) }

    public static func load(route: String, dataDirectory: URL, limit: Int = 200) throws -> Snapshot {
        let state = dataDirectory.appendingPathComponent("agent-sessions", isDirectory: true)
        let binding = state.appendingPathComponent("connect/\(scope(route: route))/codex-threads.json")
        guard FileManager.default.fileExists(atPath: binding.path) else { return Snapshot(entries: [], hasEarlier: false) }
        let mappings = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: binding))
        guard let thread = mappings[Digest.sha256(route)], UUID(uuidString: thread) != nil else {
            return Snapshot(entries: [], hasEarlier: false)
        }
        guard let file = try rollout(thread: thread, home: home(stateDirectory: state)) else { return Snapshot(entries: [], hasEarlier: false) }
        return try read(file: file, limit: limit)
    }

    private static func rollout(thread: String, home: URL) throws -> URL? {
        let files = FileManager.default
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        guard files.fileExists(atPath: root.path) else { return nil }
        var failure: Error?
        let iterator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false })
        while let path = iterator?.nextObject() as? URL {
            if path.lastPathComponent.hasPrefix("rollout-"), path.lastPathComponent.hasSuffix("-\(thread).jsonl") {
                let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if values.isRegularFile == true && values.isSymbolicLink != true { return path }
            }
        }
        if let failure { throw failure }
        return nil
    }

    public static func read(file: URL, limit: Int = 200) throws -> Snapshot {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        // Bound each read for long-running chats and ignore a partially written
        // final line. The next refresh picks up newly completed records.
        let end = try handle.seekToEnd(), maximumBytes: UInt64 = 64 * 1024 * 1024
        let start = end > maximumBytes ? end - maximumBytes : 0
        try handle.seek(toOffset: start)
        let capacity = max(1, min(limit, 10_000))
        var buffer = Data(), skippingPartial = start > 0, truncated = start > 0
        var entries: [Entry] = [], seen = Set<String>(), ordinal = 0
        func consume(_ line: Data) {
            ordinal += 1
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any], payload["type"] as? String == "item_completed",
                  let item = payload["item"] as? [String: Any] else { return }
            let kind: Entry.Kind, text: String
            var detail = ""
            switch (item["type"] as? String ?? "").lowercased() {
            case "usermessage": kind = .user; text = userContent(item["content"])
            case "agentmessage":
                kind = .assistant
                let answer = content(item["content"])
                text = (try? InteractiveReply.parse(answer))?.text ?? answer
            case "commandexecution":
                kind = .execution; text = "命令执行"
                if let command = item["command"] as? String { detail = command }
                else if let command = item["command"] as? [String] { detail = command.joined(separator: " ") }
                if let output = item["aggregated_output"] as? String, !output.isEmpty { detail += "\n\n" + String(output.prefix(12_000)) }
                if let code = item["exit_code"] as? Int { detail += "\n\nexit \(code)" }
            case "mcptoolcall", "dynamictoolcall":
                kind = .execution; text = "工具调用"
                detail = [item["server"] as? String, item["tool"] as? String].compactMap { $0 }.joined(separator: " · ")
            case "websearch": kind = .execution; text = "网页搜索"
            case "filechange": kind = .execution; text = "文件变更"
            default: return // No internal instructions or reasoning records.
            }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let identity = (payload["turn_id"] as? String ?? "") + ":" + (item["id"] as? String ?? "line-\(ordinal)")
            guard seen.insert(identity).inserted else { return }
            entries.append(Entry(id: identity, kind: kind, timestamp: object["timestamp"] as? String ?? "",
                                 text: Redaction.clean(text, limit: 32_768), detail: Redaction.clean(detail, limit: 16_000)))
            if entries.count > capacity * 2 { entries.removeFirst(capacity); truncated = true }
        }
        var remaining = end - start
        while remaining > 0 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: Int(min(remaining, 65_536))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count); buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if skippingPartial { skippingPartial = false } else { consume(line) }
            }
            if buffer.count > 8 * 1024 * 1024 { buffer.removeAll(keepingCapacity: false); skippingPartial = true; truncated = true }
        }
        return Snapshot(entries: Array(entries.suffix(capacity)), hasEarlier: truncated || entries.count > capacity)
    }

    private static func userContent(_ value: Any?) -> String {
        let text: String
        if let string = value as? String { text = string }
        else {
            let parts = (value as? [[String: Any]] ?? []).filter { $0["text"] is String }
            text = content(parts)
        }
        // The host prompt ends with the actual message JSON. Keep instructions
        // out of the history display without interpreting arbitrary user JSON.
        let messagePrompt = text.hasPrefix("你是钉钉会话回复助手。")
        let cardPrompt = text.hasPrefix("当前账号通过本面板发出的交互卡片提交了确认或补充信息。")
        guard messagePrompt || cardPrompt, let last = text.split(separator: "\n").last,
              let payload = (try? JSONSerialization.jsonObject(with: Data(last.utf8))) as? [String: Any] else { return content(value) }
        if messagePrompt, let message = payload["message"] as? String {
            let images = (payload["attached_images"] as? [String] ?? []).map { _ in "[图片]" }
            return ([message] + images).filter { !$0.isEmpty }.joined(separator: "\n")
        }
        if cardPrompt, let confirmed = payload["confirmed"] as? String, let card = payload["card"] as? String {
            let answers = (payload["answers"] as? [[String: Any]] ?? []).compactMap { answer -> String? in
                guard let question = answer["question"] as? String else { return nil }
                let response = answer["text"] as? String ?? (answer["selected"] as? [String] ?? []).joined(separator: ", ")
                return question + ": " + response
            }
            return ([confirmed, card] + answers).filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return content(value)
    }

    private static func content(_ value: Any?) -> String {
        if let string = value as? String { return string }
        return (value as? [[String: Any]] ?? []).compactMap { item in
            let type = (item["type"] as? String ?? "").lowercased()
            if ["text", "input_text", "output_text"].contains(type) { return item["text"] as? String }
            if ["image", "input_image", "localimage", "local_image"].contains(type) { return "[图片]" }
            return nil
        }.joined(separator: "\n")
    }
}
