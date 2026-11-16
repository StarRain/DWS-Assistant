import Foundation
import CryptoKit
import Darwin

public enum DashboardPaths {
    public static var dataDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dws-dashboard", isDirectory: true) }
    public static var legacyDirectory: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DWS Dashboard", isDirectory: true) }

    public static func display(_ path: String, home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        if path == home { return "~" }
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// An empty selection never falls back to the home or application launch
    /// directory. Engine processes still retain their native permission model.
    public static func agentWorkdir(_ selected: String, fallback: URL) throws -> String {
        if !selected.isEmpty { return selected }
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return fallback.path
    }

    public static func migrateLegacy(from source: URL, to target: URL) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: target.path), files.fileExists(atPath: source.path) else { return }
        let lockPath = source.appendingPathComponent("instance.lock").path
        let lock = Darwin.open(lockPath, O_RDWR)
        defer { if lock >= 0 { flock(lock, LOCK_UN); Darwin.close(lock) } }
        if files.fileExists(atPath: lockPath) {
            guard lock >= 0, flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw DashboardError.storage("旧版面板仍在运行，请先退出旧版再迁移数据") }
        }
        let staging = target.deletingLastPathComponent().appendingPathComponent(".dws-dashboard-migration-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        for name in ["config.json", "activity.json", "delivery-ledger.json", "agent-sessions"] {
            let old = source.appendingPathComponent(name)
            if files.fileExists(atPath: old.path) { try files.copyItem(at: old, to: staging.appendingPathComponent(name)) }
        }
        // Publish all copied files together; a failed migration cannot leave a
        // config without its deduplication ledger. Keep the original as backup.
        try files.moveItem(at: staging, to: target)
    }
}

public enum Digest {
    public static func sha256(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

public final class JSONStore {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    public func load<T: Decodable>(_ name: String, as: T.Type) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }
    public func save<T: Encodable>(_ value: T, to name: String) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent(name)
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

public struct DeliveryRecord: Codable, Identifiable {
    public var id: String
    public var route: String
    public var state: State
    public var date: Date
    public var card: AICardReference?
    public var replyBodyHashes: [String]?
    public var replyPreparedAt: Date?
    public var sentMessageKeys: [String]?
    public enum State: String, Codable {
        case generating, cancelled, failed, sending, delivered, accepted, unknown
        public var title: String {
            switch self {
            case .generating: return "生成中"
            case .cancelled: return "已取消"
            case .failed: return "生成失败"
            case .sending: return "发送中"
            case .delivered: return "已确认投递"
            case .accepted: return "卡片已提交，展示待确认"
            case .unknown: return "投递待确认"
            }
        }
    }
}

/// All intents remain durable, including unknown outcomes. Never evict an uncertain send.
public final class DeliveryLedger {
    private let store: JSONStore
    public private(set) var records: [String: DeliveryRecord]
    public init(store: JSONStore) throws {
        self.store = store
        records = try store.load("delivery-ledger.json", as: [String: DeliveryRecord].self) ?? [:]
        for key in Array(records.keys) {
            if records[key]?.state == .sending { records[key]?.state = .unknown }
            if records[key]?.state == .generating { records[key]?.state = .cancelled }
        }
        try store.save(records, to: "delivery-ledger.json")
    }
    public static func key(identity: String, profile: String, target: String, messageID: String) -> String {
        // JSON encoding avoids delimiter collisions in stable IDs.
        let data = try! JSONEncoder().encode([identity, profile, target, messageID])
        return Digest.sha256(String(decoding: data, as: UTF8.self))
    }
    public func reserve(_ key: String, route: String) throws -> Bool {
        guard records[key] == nil else { return false }
        var next = records
        next[key] = DeliveryRecord(id: key, route: route, state: .generating, date: Date())
        try store.save(next, to: "delivery-ledger.json"); records = next
        return true
    }
    public func mark(_ key: String, _ state: DeliveryRecord.State) throws {
        var next = records; next[key]?.state = state
        try store.save(next, to: "delivery-ledger.json"); records = next
    }
    public func attachCard(_ reference: AICardReference, to key: String) throws {
        guard records[key] != nil else { throw DashboardError.storage("缺少卡片投递记录") }
        var next = records; next[key]?.card = reference
        try store.save(next, to: "delivery-ledger.json"); records = next
    }
    public func reserveCardAction(_ event: CardActionEvent, recordID: String, conversation: Conversation, now: Date = Date(), currentSenderID: String? = nil) throws -> CardActionJob? {
        guard let record = records[recordID], record.route == conversation.id.uuidString, record.state == .accepted,
              let reference = record.card, reference.interaction?.consumed == false else { return nil }
        let submission = try event.validate(reference: reference, conversation: conversation, now: now, currentSenderID: currentSenderID)
        return try reserveCardJob(record: record, action: event.action, submission: submission, now: now)
    }
    public func reserveExpiredCard(recordID: String, conversation: Conversation, now: Date = Date()) throws -> CardActionJob? {
        guard let record = records[recordID], record.route == conversation.id.uuidString, record.state == .accepted,
              let reference = record.card, let interaction = reference.interaction, !interaction.consumed,
              interaction.expiresAt <= now, !reference.bizID.isEmpty,
              reference.profile == conversation.profile, reference.target == conversation.stableID,
              conversation.listen, conversation.autoReply, conversation.replyFormat == .aiCard,
              interaction.configuration == (try CardInteraction.fingerprint(conversation)) else { return nil }
        return try reserveCardJob(record: record, action: "expire", submission: "", now: now)
    }
    private func reserveCardJob(record: DeliveryRecord, action: String, submission: String, now: Date) throws -> CardActionJob? {
        guard var reference = record.card, let interaction = reference.interaction, !interaction.consumed else { return nil }
        let key = Digest.sha256("card-action|" + record.id + "|" + interaction.token)
        guard records[key] == nil else { return nil }
        // Consume the form and reserve its job in the same atomic write. A
        // click and expiry share a claim, so neither can reuse the other's form.
        reference.interaction?.consumed = true
        var next = records
        next[record.id]?.card = reference
        next[key] = DeliveryRecord(id: key, route: record.route, state: .generating, date: now, card: reference)
        try store.save(next, to: "delivery-ledger.json"); records = next
        return CardActionJob(key: key, reference: reference, action: action, submission: submission)
    }
    private static func bodyKey(_ text: String, profile: String, target: String) -> String {
        key(identity: "reply-body", profile: profile, target: target,
            messageID: String(text.prefix(12_000)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
    public func prepareReplyEcho(_ text: String, conversation: Conversation, key: String) throws {
        var texts = [text, AICardReply.textOnlyMarkdown(text)]
        if conversation.replyFormat == .aiCard {
            // Keep suppressing delayed echoes of cards sent before the rename.
            texts += [AICardReply.summary, "AI 助手回复"]
        }
        var next = records
        // A late echo of the processing card must remain suppressed after its
        // body has been replaced with the final answer.
        next[key]?.replyBodyHashes = Array(Set((records[key]?.replyBodyHashes ?? []) + texts.map { Self.bodyKey($0, profile: conversation.profile, target: conversation.stableID) }))
        next[key]?.replyPreparedAt = Date()
        try store.save(next, to: "delivery-ledger.json"); records = next
    }
    public func rememberSentMessages(_ result: CommandResult, conversation: Conversation, key: String) throws {
        guard let object = try? JSONOutput.object(result) else { return }
        var ids = Set<String>()
        func visit(_ value: Any, depth: Int = 0) {
            guard depth < 8 else { return }
            if let row = value as? [String: Any] {
                for name in ["openMessageId", "messageId", "openMsgId", "message_id"] {
                    if let id = row[name] as? String, !id.isEmpty { ids.insert(id) }
                }
                for nested in row.values { visit(nested, depth: depth + 1) }
            } else if let rows = value as? [Any] { for row in rows { visit(row, depth: depth + 1) } }
        }
        visit(object)
        guard !ids.isEmpty else { return }
        var next = records
        next[key]?.sentMessageKeys = ids.map { Self.key(identity: "sent", profile: conversation.profile, target: conversation.stableID, messageID: $0) }
        try store.save(next, to: "delivery-ledger.json"); records = next
    }
    public func isReplyEcho(_ event: IMEvent, conversation: Conversation, now: Date = Date()) -> Bool {
        let id = Self.key(identity: "sent", profile: conversation.profile, target: conversation.stableID, messageID: event.messageID)
        let body = Self.bodyKey(event.content, profile: conversation.profile, target: conversation.stableID)
        return records.values.contains {
            ($0.sentMessageKeys?.contains(id) == true) ||
            (now.timeIntervalSince($0.replyPreparedAt ?? $0.date) < 15 * 60 && $0.replyBodyHashes?.contains(body) == true)
        }
    }
}

public enum Redaction {
    public static func clean(_ text: String, limit: Int = 4000) -> String {
        var result = text
        let patterns = [
            #"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#,
            #"(?i)(https://oapi\.dingtalk\.com/robot/send)[^\s\"<>]*"#,
            #"(?i)((?:access[_-]?token|refresh[_-]?token|client[_-]?secret|secret|authorization|webhook[_-]?token|sign)\s*[\"']?\s*[:=]\s*[\"']?)[^\s\"',}&]+"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "$1[已隐藏]")
            }
        }
        return String(result.prefix(max(0, limit)))
    }
}
