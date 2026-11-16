import Foundation

public struct AICardReference: Codable, Equatable {
    public var bizID: String
    public var surfaceID: String
    public var profile: String
    public var target: String
    public var creationContent: String
    public var finishContent: String
    public var interaction: CardInteraction? = nil
}

/// The host constructs every component and action. AI output may describe a
/// bounded form, but cannot supply executable actions, recipients or A2UI.
public struct AICardReply {
    public static let summary = "DWS助手回复"
    public let surfaceID: String
    public let creationContent: String
    public let finishContent: String
    public let replacementContent: String
    public let interaction: CardInteraction?
    public let body: String

    public init(text: String, key: String, conversation: Conversation? = nil, conversationID: String = "", surfaceID: String? = nil, processing: Bool = false, progress: AgentExecutionProgress = .init()) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else {
            throw DashboardError.invalid("回复为空或超过 32 KiB")
        }
        self.surfaceID = surfaceID ?? "dws-reply-" + String(Digest.sha256(key).prefix(24))
        let surfaceID = self.surfaceID
        let form = try InteractiveReply.parse(text)
        body = form?.text ?? text
        if let form, let conversation {
            try Validation.cardInteractionTimeout(conversation.cardInteractionTimeout)
            let createdAt = Date()
            interaction = CardInteraction(token: UUID().uuidString, form: form,
                                          configuration: try CardInteraction.fingerprint(conversation),
                                          conversationID: conversationID, expiresAt: createdAt.addingTimeInterval(TimeInterval(conversation.cardInteractionTimeout)),
                                          createdAt: createdAt)
        } else if form != nil { throw DashboardError.invalid("交互卡片缺少会话绑定") }
        else { interaction = nil }
        var children = ["answer"]
        var components: [[String: Any]] = [["id": "answer", "component": "Markdown", "content": Self.textOnlyMarkdown(body)]]
        var model: [String: Any] = ["status": "ready"]
        if processing {
            guard interaction == nil else { throw DashboardError.invalid("处理中卡片不能包含待提交表单") }
            children = ["execution-progress"]; model["status"] = "processing"
            components = [
                ["id": "execution-progress", "component": "CollapsiblePanel", "title": "[AIGenerating]" + body,
                 "variant": "reasoning", "textEffect": "shimmer", "children": ["answer"], "fallbackMarkdown": body],
                ["id": "answer", "component": "Markdown", "content": "请稍候，结果会更新在此卡片中。"]
            ]
        }
        if let interaction {
            var answers: [String: Any] = [:], checks: [[String: Any]] = []
            for q in interaction.form.questions {
                let id = "field-" + q.id, path = "/answers/\(q.id)/" + (q.type == .text ? "custom" : "selected")
                answers[q.id] = ["selected": [String](), "custom": ""]
                if q.type == .text {
                    components.append(["id": id, "component": "TextField", "label": q.label, "placeholder": "请输入", "variant": "longText", "value": ["path": path]])
                } else {
                    children.append(id + "-label")
                    components.append(["id": id + "-label", "component": "Text", "text": q.label])
                    components.append(["id": id, "component": "ChoicePicker", "label": q.label,
                                       "variant": q.type == .single ? "mutuallyExclusive" : "multipleSelection", "displayStyle": "checkbox",
                                       "options": q.options.map { ["label": $0.label, "value": $0.id] }, "value": ["path": path]])
                }
                children.append(id)
                if q.required {
                    let condition: [String: Any] = q.type == .text
                        ? ["call": "regex", "args": ["value": ["path": path], "pattern": "[\\s\\S]*\\S[\\s\\S]*"]]
                        : ["call": "required", "args": ["value": ["path": path]]]
                    checks.append(["condition": condition, "message": "请填写：" + q.label])
                }
            }
            model["answers"] = answers
            children += ["actions", "interaction-hint", "interaction-countdown"]
            components.append(["id": "actions", "component": "Row", "children": ["cancel", "submit"]])
            for action in ["cancel", "submit"] {
                var context: [String: Any] = ["dashboardProtocol": "dws-dashboard-v1", "interactionToken": interaction.token, "surfaceId": surfaceID, "action": action]
                if action == "submit" { context["answers"] = ["path": "/answers"] }
                var button: [String: Any] = ["id": action, "component": "Button", "child": action + "-label",
                                            "variant": action == "submit" ? "primary" : "default",
                                            "action": ["event": ["name": "dws_dashboard_" + action, "context": context]]]
                if action == "submit" && !checks.isEmpty {
                    // Input edits are local to DingTalk. Its disabled field is
                    // literal-only, and visibility-swapped buttons can retain
                    // their initial state after edits. Keep one primary action;
                    // native checks read the latest values when clicked. The
                    // host validates the callback again before claiming a task.
                    button["checks"] = checks
                }
                components += [button, ["id": action + "-label", "component": "Text", "text": action == "submit" ? interaction.form.submitLabel : "取消"]]
            }
            let deadlineFormatter = DateFormatter()
            deadlineFormatter.locale = Locale(identifier: "zh_CN")
            deadlineFormatter.dateFormat = "MM-dd HH:mm:ss"
            // The renderer ticks locally using the same absolute deadline as
            // callback validation. No polling writes or form resets are needed.
            components.append(["id": "interaction-countdown", "component": "Countdown",
                "endTime": Int64(interaction.expiresAt.timeIntervalSince1970 * 1_000),
                "prefix": "请在 ", "suffix": " 内操作！", "gravity": "left",
                "fallbackMarkdown": "操作截止时间：" + deadlineFormatter.string(from: interaction.expiresAt)])
            components.append(["id": "interaction-hint", "component": "Text", "text": "提交后继续处理，结果更新在此卡片。"])
        }
        if !processing && !progress.isEmpty {
            children.insert("execution-progress", at: 0)
            components += progress.components(running: false)
        }
        children.append("ai-attribution")
        components.append(Self.attribution)
        components.insert(["id": "root", "component": "Column", "children": children], at: 0)
        let updates: [[String: Any]] = [
            ["version": "v1.0", "updateDataModel": ["surfaceId": surfaceID, "path": "/", "value": model]],
            ["version": "v1.0", "updateComponents": ["surfaceId": surfaceID, "components": components]]
        ]
        creationContent = try Self.serialize([["version": "v1.0", "createSurface": ["surfaceId": surfaceID, "catalogId": "https://dingtalk.com/card/a2ui/catalogs/public/catalog.json"]]] + updates)
        replacementContent = try Self.serialize(updates)
        finishContent = try Self.serialize([
            ["version": "v1.0", "updateDataModel": ["surfaceId": surfaceID, "path": "/status", "value": "finished"]]
        ])
    }

    /// This reply mode does not authorize uploading attachments. Converting
    /// image syntax to ordinary links avoids DWS's automatic local-image upload.
    public static func textOnlyMarkdown(_ text: String) -> String {
        text.replacingOccurrences(of: "![", with: "[")
    }

    private static func serialize(_ messages: [[String: Any]]) throws -> String {
        let strings = try messages.map { String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self) }
        return String(decoding: try JSONEncoder().encode(strings), as: UTF8.self)
    }

    public func pendingReference(conversation: Conversation) -> AICardReference {
        AICardReference(bizID: "", surfaceID: surfaceID, profile: conversation.profile, target: conversation.stableID,
                        creationContent: creationContent, finishContent: finishContent, interaction: interaction)
    }

    public func reference(from receipt: CommandResult, conversation: Conversation) throws -> AICardReference {
        let envelopes = try Self.receiptEnvelopes(receipt)
        guard envelopes.contains(where: { $0["success"] as? Bool == true || $0["requestAccepted"] as? Bool == true }),
              let bizID = envelopes.compactMap({ $0["bizId"] as? String }).first, !bizID.isEmpty else {
            throw DashboardError.command("AI 卡片创建结果待确认，未取得服务端卡片 ID；不会重复创建")
        }
        try Validation.stableID(bizID, name: "AI 卡片 ID")
        return AICardReference(bizID: bizID, surfaceID: surfaceID, profile: conversation.profile, target: conversation.stableID,
                               creationContent: creationContent, finishContent: finishContent, interaction: interaction)
    }

    public func replacing(_ reference: AICardReference, conversation: Conversation) -> AICardReference {
        var result = pendingReference(conversation: conversation)
        result.bizID = reference.bizID
        return result
    }

    private static var attribution: [String: Any] {
        ["id": "ai-attribution", "component": "Text", "text": "「此消息由DWS助手通过DWS CLI自动回复」",
         "colorToken": "common_level2_base_color", "sizeToken": "common_footnote_text_style__font_size"]
    }

    public static func progressContent(_ reference: AICardReference, progress: AgentExecutionProgress) throws -> String {
        try serialize([["version": "v1.0", "updateComponents": ["surfaceId": reference.surfaceID, "components": [
            ["id": "root", "component": "Column", "children": ["execution-progress", "ai-attribution"]], attribution
        ] + progress.components(running: true)]]])
    }

    public static func statusContent(_ reference: AICardReference, status: String, progress: AgentExecutionProgress = .init()) throws -> String {
        let children = (progress.isEmpty ? [] : ["execution-progress"]) + ["answer", "interaction-status", "ai-attribution"]
        return try serialize([["version": "v1.0", "updateComponents": ["surfaceId": reference.surfaceID, "components": [
            ["id": "root", "component": "Column", "children": children],
            ["id": "answer", "component": "Markdown", "content": textOnlyMarkdown(reference.interaction?.form.text ?? "")],
            ["id": "interaction-status", "component": "Text", "text": status], attribution
        ] + (progress.isEmpty ? [] : progress.components(running: false, failed: true))]]])
    }

    public static func updateAccepted(_ receipt: CommandResult, reference: AICardReference) throws -> Bool {
        let envelopes = try receiptEnvelopes(receipt)
        if envelopes.compactMap({ $0["bizId"] as? String }).contains(where: { $0 != reference.bizID }) {
            throw DashboardError.command("AI 卡片更新回执与目标不一致，结果待确认")
        }
        return envelopes.contains { $0["success"] as? Bool == true || $0["requestAccepted"] as? Bool == true }
    }

    private static func receiptEnvelopes(_ receipt: CommandResult) throws -> [[String: Any]] {
        var current = try JSONOutput.object(receipt), result: [[String: Any]] = []
        for _ in 0..<6 {
            guard current["ok"] as? Bool != false, current["success"] as? Bool != false, current["error"] == nil else {
                throw DashboardError.command("AI 卡片接口未确认成功，保留当前记录且不自动重发")
            }
            result.append(current)
            guard let nested = current["data"] as? [String: Any] ?? current["result"] as? [String: Any] else { break }
            current = nested
        }
        return result
    }
}
