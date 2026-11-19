import Foundation

/// A live bridge callback, never a model-produced interaction form.
public struct EngineApprovalRequest: Decodable, Equatable, Identifiable {
    public let type: String
    public let version: Int
    public let token: String
    public let kind: String
    public let details: String
    public let expiresAt: Double
    public var id: String { token }
    public var deadline: Date { Date(timeIntervalSince1970: expiresAt / 1_000) }
    private enum CodingKeys: String, CodingKey { case type, version, token, kind, details; case expiresAt = "expires_at" }

    public static func parse(_ line: String, now: Date = Date()) -> Self? {
        // The 48 KiB JSON details are escaped again inside the bridge envelope.
        guard line.utf8.count <= 128 * 1024, let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.type == "dws_engine_approval", value.version == 1,
              value.token.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              ["command", "files", "permissions"].contains(value.kind),
              !value.details.isEmpty, value.details.utf8.count <= 48 * 1024,
              value.deadline > now, value.deadline <= now.addingTimeInterval(95) else { return nil }
        return value
    }
    public var title: String {
        switch kind { case "files": return "批准文件修改"; case "permissions": return "批准本轮权限申请"; default: return "批准本次操作" }
    }
    // Log redaction defaults to 4,000 characters; an approval must retain the
    // entire bounded action, especially the tail of a command or file diff.
    public var displayDetails: String { Redaction.clean(details, limit: Int.max) }
    public func response(approved: Bool, now: Date = Date()) throws -> String {
        let value: [String: Any] = ["type": "dws_engine_approval_response", "version": 1, "token": token,
                                    "decision": approved && deadline > now ? "accept" : "decline"]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) + "\n"
    }
    public func card(conversation: Conversation, conversationID: String) throws -> AICardReply {
        let text = "Codex 原生审批：\(title)\n\n以下是引擎正在等待批准的具体请求。仅批准本次操作；权限申请仅在本轮生效。\n\n```json\n\(displayDetails)\n```"
        let form: [String: Any] = ["kind": "dws_interaction", "text": text, "submitLabel": "批准本次操作", "questions": [Any]()]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: form), as: UTF8.self)
        return try AICardReply(text: json, key: "native-approval|" + token, conversation: conversation, conversationID: conversationID, interactionExpiresAt: deadline,
                              interactionHint: "批准或拒绝会返回当前 Codex 请求；执行结果请查看任务回复。")
    }
}
