import XCTest
@testable import AssistantCore

final class CardInteractionTests: XCTestCase {
    private let form = #"{"kind":"dws_interaction","text":"请选择构建类型并补充备注。","submitLabel":"确认打包","questions":[{"id":"q1","label":"构建类型","type":"single","options":[{"id":"debug","label":"Debug"},{"id":"release","label":"Release"}]},{"id":"q2","label":"备注","type":"text","required":false},{"id":"q3","label":"额外选项","type":"multiple","required":false,"options":[{"id":"a","label":"选项 A"},{"id":"b","label":"选项 B"}]}]}"#
    private func conversation() -> Conversation {
        var c = Conversation(); c.profile = "corp:user"; c.stableID = "cid-card"; c.listen = true; c.autoReply = true; c.replyFormat = .aiCard
        return c
    }
    private func reference(_ c: Conversation) throws -> AICardReference {
        let card = try AICardReply(text: form, key: "key", conversation: c, conversationID: c.stableID)
        return try card.reference(from: CommandResult(status: 0, stdout: #"{"success":true,"result":{"bizId":"server-card"}}"#, stderr: ""), conversation: c)
    }
    private func event(_ ref: AICardReference, action: String = "submit", answers: [String: Any]? = nil, legacy: Bool = false,
                       edit: (inout [String: Any]) -> Void = { _ in }) throws -> CardActionEvent {
        var context: [String: Any] = ["assistantProtocol": "dws-assistant-v1", "interactionToken": ref.interaction!.token,
            "surfaceId": ref.surfaceID, "action": action,
            "answers": answers ?? ["q1": ["selected": ["release"]], "q2": ["custom": "备注 $(do-not-execute)"], "q3": ["selected": [String]()]],
            "questions": [["id": "q1", "options": [["id": "release", "label": "tampered-label"]]]]]
        edit(&context)
        if legacy, let answers = context["answers"] {
            context["answers"] = String(decoding: try JSONSerialization.data(withJSONObject: answers), as: UTF8.self)
        }
        var body: [String: Any] = ["bizInfoDTO": ["bizId": ref.bizID], "conversationContextDTO": ["cid": ref.target],
                                  "operatorDTO": ["uid": 10001], "triggerTimestamp": Int64(Date().timeIntervalSince1970 * 1000)]
        if legacy { body["context"] = context } else { body["actionData"] = ["context": context] }
        let root: [String: Any] = ["type": "user_card_action_triggered", "event_id": UUID().uuidString, "payload": ["body": body]]
        return try CardActionEvent(line: String(decoding: JSONSerialization.data(withJSONObject: root), as: UTF8.self))
    }
    private func messages(_ text: String) throws -> [[String: Any]] {
        try JSONDecoder().decode([String].self, from: Data(text.utf8)).map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
    }

    private func nativeEvent(_ ref: AICardReference, action: String, edit: (inout [String: Any]) -> Void = { _ in }) throws -> CardActionEvent {
        let context: [String: Any] = ["assistantProtocol": "dws-assistant-v1", "interactionToken": ref.interaction!.token,
            "surfaceId": ref.surfaceID, "action": action,
            "answers": ["q1": ["selected": ["release"]], "q2": ["custom": "备注"], "q3": ["selected": [String]()]]]
        var body: [String: Any] = ["a2uiEvent": ["version": "1.0", "action": ["name": "dws_assistant_" + action,
            "surfaceId": ref.surfaceID, "sourceComponentId": action, "context": context,
            "timestamp": ISO8601DateFormatter().string(from: Date())]],
            "bizInfoDTO": ["bizId": ref.bizID], "operatorDTO": ["openDingTalkId": "current-open-id"],
            "conversationContextDTO": ["openConversationId": ref.target],
            "triggerTimestamp": Int64(Date().timeIntervalSince1970 * 1000)]
        edit(&body)
        let data = try JSONSerialization.data(withJSONObject: ["type": "user_card_action_triggered", "event_id": "native-action",
            "timestamp": Int64(Date().timeIntervalSince1970 * 1000), "payload": ["body": body]])
        return try CardActionEvent(line: String(decoding: data, as: UTF8.self))
    }

    func testOldCardCallbacksRemainValidatedAfterProtocolRename() throws {
        let c = conversation(), ref = try reference(c)
        for name in ["submit", "cancel"] {
            let old = try nativeEvent(ref, action: name) { body in
                var event = body["a2uiEvent"] as! [String: Any]
                var action = event["action"] as! [String: Any]
                var context = action["context"] as! [String: Any]
                context.removeValue(forKey: AssistantCardProtocol.contextKey)
                context[LegacyCompatibility.cardContextKey] = LegacyCompatibility.cardProtocol
                action["context"] = context; action["name"] = LegacyCompatibility.cardActionPrefix + name
                event["action"] = action; body["a2uiEvent"] = event
            }
            let result = try old.validate(reference: ref, conversation: c, currentSenderID: "current-open-id")
            XCTAssertTrue(name == "cancel" ? result == "已取消" : result.contains("Release"))
            XCTAssertThrowsError(try old.validate(reference: ref, conversation: c, currentSenderID: "other"))
        }
        XCTAssertThrowsError(try event(ref) { context in
            context[LegacyCompatibility.cardContextKey] = LegacyCompatibility.cardProtocol
        })
        XCTAssertThrowsError(try nativeEvent(ref, action: "submit") { body in
            var event = body["a2uiEvent"] as! [String: Any]
            var action = event["action"] as! [String: Any]
            action["name"] = LegacyCompatibility.cardActionPrefix + "submit"
            event["action"] = action; body["a2uiEvent"] = event
        })
        let card = try AICardReply(text: form, key: "new-card", conversation: c, conversationID: c.stableID)
        XCTAssertTrue(card.replacementContent.contains(AssistantCardProtocol.version))
        XCTAssertTrue(card.replacementContent.contains(AssistantCardProtocol.actionPrefix + "submit"))
        XCTAssertFalse(card.replacementContent.contains(LegacyCompatibility.cardProtocol))
    }

    func testNativeA2UIActionsRequireCurrentOperatorAndKeepCardBinding() throws {
        let c = conversation(), ref = try reference(c)
        let cancel = try nativeEvent(ref, action: "cancel")
        XCTAssertEqual(cancel.operatorOpenDingTalkID, "current-open-id"); XCTAssertEqual(cancel.operatorUID, "")
        XCTAssertEqual(try cancel.validate(reference: ref, conversation: c, currentSenderID: "current-open-id"), "已取消")
        XCTAssertThrowsError(try cancel.validate(reference: ref, conversation: c))
        XCTAssertThrowsError(try cancel.validate(reference: ref, conversation: c, currentSenderID: "other"))
        let submit = try nativeEvent(ref, action: "submit")
        XCTAssertTrue(try submit.validate(reference: ref, conversation: c, currentSenderID: "current-open-id").contains("Release"))
        let wrongConversation = try nativeEvent(ref, action: "cancel") { $0["conversationContextDTO"] = ["openConversationId": "other"] }
        XCTAssertThrowsError(try wrongConversation.validate(reference: ref, conversation: c, currentSenderID: "current-open-id"))
        XCTAssertThrowsError(try nativeEvent(ref, action: "cancel") { body in
            body["a2uiEvent"] = ["action": ["name": "dws_assistant_cancel"]]
            body["context"] = ["assistantProtocol": "dws-assistant-v1", "interactionToken": ref.interaction!.token,
                "surfaceId": ref.surfaceID, "action": "cancel"]
        }, "Malformed native context must not fall back to a legacy copy")
    }

    func testFormUsesHostComponentsBindingsAndLiteralActionIdentity() throws {
        let c = conversation()
        let card = try AICardReply(text: form, key: "key", conversation: c, conversationID: "cid-card")
        let initial = try messages(card.creationContent)
        let components = (initial[2]["updateComponents"] as! [String: Any])["components"] as! [[String: Any]]
        XCTAssertEqual(components.filter { $0["component"] as? String == "ChoicePicker" }.count, 2)
        XCTAssertEqual(components.filter { $0["component"] as? String == "TextField" }.count, 1)
        let submit = try XCTUnwrap(components.first { $0["id"] as? String == "submit" })
        let event = (submit["action"] as! [String: Any])["event"] as! [String: Any]
        let context = event["context"] as! [String: Any]
        XCTAssertEqual(context["interactionToken"] as? String, card.interaction?.token)
        XCTAssertEqual(context["surfaceId"] as? String, card.surfaceID)
        XCTAssertEqual((context["answers"] as? [String: String])?["path"], "/answers")
        XCTAssertNil((submit["action"] as? [String: Any])?["functionCall"])
        XCTAssertEqual(card.interaction?.configuration, try CardInteraction.fingerprint(c))
        XCTAssertFalse(try messages(card.replacementContent).contains { $0["createSurface"] != nil })
        XCTAssertThrowsError(try AICardReply(text: form, key: "no-conversation"))
        XCTAssertThrowsError(try AICardReply(text: form.replacingOccurrences(of: "q1", with: "../../secret"), key: "bad", conversation: c))
    }

    func testWaitTimeoutDefaultsMigratesAndDrivesEachNewCardDeadline() throws {
        let original = conversation()
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let legacy = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(Conversation.self, from: legacy)
        XCTAssertEqual(decoded.cardInteractionTimeout, 60)
        XCTAssertEqual(try CardInteraction.fingerprint(decoded), Digest.sha256(String(decoding: legacy, as: UTF8.self)))
        for seconds in [10, 60, 120, 600, 86_400] {
            var c = decoded; c.cardInteractionTimeout = seconds
            XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: encoder.encode(c)).cardInteractionTimeout, seconds)
            let card = try AICardReply(text: form, key: "configured-wait", conversation: c)
            let ref = try card.reference(from: CommandResult(status: 0, stdout: #"{"success":true,"result":{"bizId":"server-card"}}"#, stderr: ""), conversation: c)
            let interaction = try XCTUnwrap(ref.interaction), createdAt = try XCTUnwrap(interaction.createdAt)
            XCTAssertEqual(interaction.expiresAt.timeIntervalSince(createdAt), TimeInterval(seconds), accuracy: 0.001)
            let components = try XCTUnwrap(try messages(card.creationContent).compactMap {
                ($0["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]
            }.first)
            let timer = try XCTUnwrap(components.first { $0["id"] as? String == "interaction-countdown" })
            XCTAssertEqual(timer["component"] as? String, "Countdown")
            XCTAssertEqual(timer["endTime"] as? Int64, Int64(interaction.expiresAt.timeIntervalSince1970 * 1_000))
            XCTAssertEqual(timer["prefix"] as? String, "请在 ")
            XCTAssertEqual(timer["suffix"] as? String, " 内操作！")
            XCTAssertNil(timer["onComplete"], "Client ticking must not execute tasks or reset form selections")
            let rootChildren = try XCTUnwrap(components.first { $0["id"] as? String == "root" }?["children"] as? [String])
            XCTAssertEqual(Array(rootChildren.suffix(3)), ["interaction-hint", "interaction-countdown", "ai-attribution"])
            XCTAssertEqual(components.first { $0["id"] as? String == "interaction-hint" }?["text"] as? String, "提交后继续处理，结果更新在此卡片。")
            let callback = try event(ref)
            XCTAssertNoThrow(try callback.validate(reference: ref, conversation: c, now: interaction.expiresAt.addingTimeInterval(-0.001)))
            XCTAssertThrowsError(try callback.validate(reference: ref, conversation: c, now: interaction.expiresAt))
            var changed = c; changed.cardInteractionTimeout = seconds == 120 ? 180 : 120
            XCTAssertThrowsError(try callback.validate(reference: ref, conversation: changed))
        }
        for seconds in [0, 9, 86_401] {
            var c = decoded; c.cardInteractionTimeout = seconds
            var config = AssistantConfig(); config.conversations = [c]
            XCTAssertThrowsError(try Validation.configuration(config))
            XCTAssertThrowsError(try AICardReply(text: form, key: "invalid-wait", conversation: c))
        }
    }

    func testPreviouslyIssuedCardsKeepTheirRecordedDeadline() throws {
        let c = conversation()
        var ref = try reference(c)
        ref.interaction?.createdAt = nil
        ref.interaction?.expiresAt = Date().addingTimeInterval(86_400)
        let decoded = try JSONDecoder().decode(AICardReference.self, from: JSONEncoder().encode(ref))
        XCTAssertNil(decoded.interaction?.createdAt)
        XCTAssertEqual(decoded.interaction?.expiresAt, ref.interaction?.expiresAt)
        XCTAssertNoThrow(try event(decoded).validate(reference: decoded, conversation: c))
    }

    func testCallbacksUseStoredLabelsAndSupportLegacyAndEmptyOptionalAnswers() throws {
        let c = conversation()
        let ref = try reference(c)
        for legacy in [false, true] {
            let callback = try event(ref, legacy: legacy)
            let result = try callback.validate(reference: ref, conversation: c)
            XCTAssertTrue(result.contains("Release")); XCTAssertTrue(result.contains("do-not-execute"))
            XCTAssertFalse(result.contains("tampered-label"))
            XCTAssertEqual(callback.operatorUID, "10001")
        }
        let cancel = try event(ref, action: "cancel", answers: [:])
        XCTAssertEqual(try cancel.validate(reference: ref, conversation: c), "已取消")
        for answers: [String: Any] in [["q1": ["selected": ["not-an-option"]]], ["q1": ["selected": ["debug", "release"]]], [:],
                                       ["q1": ["selected": ["release"]], "extra": ["custom": "injected"]]] {
            XCTAssertThrowsError(try event(ref, answers: answers).validate(reference: ref, conversation: c))
        }
    }

    func testScriptUploadAndNotificationChoicesReachTheConfirmedTaskUnchanged() throws {
        var c = conversation(); c.agent.permission = .full
        let options = [
            ["id": "debug_upload", "label": "Debug → 上传到蒲公英"],
            ["id": "debug_notify", "label": "Debug → 上传到蒲公英 → 钉钉通知"],
            ["id": "release", "label": "Release（含调试工具）→ 仅构建 APK"],
            ["id": "release_upload", "label": "Release（含调试工具）→ 上传到蒲公英"],
            ["id": "release_notify", "label": "Release（含调试工具）→ 上传到蒲公英 → 钉钉通知"]
        ]
        let definition: [String: Any] = ["kind": "dws_interaction", "text": "请选择 scripts/publish.sh 的快捷流程。",
            "questions": [["id": "q1", "label": "打包方式", "type": "single", "options": options]]]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: definition), as: UTF8.self)
        let card = try AICardReply(text: text, key: "script-menu", conversation: c, conversationID: c.stableID)
        let components = (try messages(card.creationContent)[2]["updateComponents"] as! [String: Any])["components"] as! [[String: Any]]
        let picker = try XCTUnwrap(components.first { $0["component"] as? String == "ChoicePicker" })
        let rendered = try XCTUnwrap(picker["options"] as? [[String: String]])
        XCTAssertEqual(rendered.map { $0["label"] }, options.map { $0["label"] })
        let ref = try card.reference(from: CommandResult(status: 0, stdout: #"{"success":true,"result":{"bizId":"script-card"}}"#, stderr: ""), conversation: c)
        for option in options {
            let submission = try event(ref, answers: ["q1": ["selected": [option["id"]!]]]).validate(reference: ref, conversation: c)
            let prompt = try CardActionJob(key: "script-choice", reference: ref, action: "submit", submission: submission).prompt()
            XCTAssertTrue(prompt.contains(option["label"]!))
            XCTAssertFalse(prompt.contains("直接调用原脚本"), "Confirmed tasks must not gain a host-specific execution workflow")
            XCTAssertFalse(prompt.contains("不调用钉钉、邮件等工具另外发送或上传"))
        }
        XCTAssertThrowsError(try event(ref, answers: ["q1": ["selected": ["unknown"]]]).validate(reference: ref, conversation: c))
    }

    func testWrongCardScopeConfigurationAndExpiredFormsAreRejected() throws {
        let c = conversation()
        let ref = try reference(c), callback = try event(reference(c))
        XCTAssertThrowsError(try callback.validate(reference: ref, conversation: c), "A fresh nonce is issued for each rendered form")
        let valid = try event(ref)
        for field in ["biz", "surface", "profile", "target", "consumed"] {
            var changed = ref
            switch field {
            case "biz": changed.bizID = "other"
            case "surface": changed.surfaceID = "other"
            case "profile": changed.profile = "other:user"
            case "target": changed.target = "other"
            default: changed.interaction?.consumed = true
            }
            XCTAssertThrowsError(try valid.validate(reference: changed, conversation: c))
        }
        var changed = c; changed.agent.permission = .full
        XCTAssertThrowsError(try valid.validate(reference: ref, conversation: changed))
        XCTAssertThrowsError(try valid.validate(reference: ref, conversation: c, now: Date().addingTimeInterval(86_401)))
        XCTAssertThrowsError(try event(ref) { $0["assistantProtocol"] = "foreign" })
    }

    func testClaimIsAtomicDurableAndOneUseAcrossDifferentEventIDs() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-claim-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONStore(directory: directory), ledger = try DeliveryLedger(store: store), c = conversation()
        let ref = try reference(c)
        XCTAssertTrue(try ledger.reserve("original", route: c.id.uuidString))
        try ledger.attachCard(ref, to: "original"); try ledger.mark("original", .accepted)
        let job = try XCTUnwrap(ledger.reserveCardAction(event(ref), recordID: "original", conversation: c))
        XCTAssertNil(try ledger.reserveCardAction(event(ref), recordID: "original", conversation: c))
        let reloaded = try DeliveryLedger(store: store)
        XCTAssertTrue(reloaded.records["original"]?.card?.interaction?.consumed == true)
        XCTAssertEqual(reloaded.records[job.key]?.state, .cancelled)
        XCTAssertNil(try reloaded.reserveCardAction(event(ref), recordID: "original", conversation: c))
    }

    func testExpiryClaimsOnlyDueCardsAndCannotBeReplayedByAClickOrRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-expiry-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONStore(directory: directory), ledger = try DeliveryLedger(store: store), c = conversation()
        let ref = try reference(c), deadline = try XCTUnwrap(ref.interaction?.expiresAt)
        XCTAssertTrue(try ledger.reserve("original", route: c.id.uuidString))
        try ledger.attachCard(ref, to: "original"); try ledger.mark("original", .accepted)
        XCTAssertNil(try ledger.reserveExpiredCard(recordID: "original", conversation: c, now: deadline.addingTimeInterval(-1)))
        for field in ["configuration", "profile", "target", "listening"] {
            var changed = c
            switch field {
            case "configuration": changed.agent.timeout += 10
            case "profile": changed.profile = "other:user"
            case "target": changed.stableID = "another-card"
            default: changed.listen = false
            }
            XCTAssertNil(try ledger.reserveExpiredCard(recordID: "original", conversation: changed, now: deadline))
        }
        let job = try XCTUnwrap(ledger.reserveExpiredCard(recordID: "original", conversation: c, now: deadline))
        XCTAssertEqual(job.action, "expire"); XCTAssertEqual(job.submission, "")
        XCTAssertEqual(job.reference.bizID, ref.bizID)
        XCTAssertNil(try ledger.reserveCardAction(event(ref), recordID: "original", conversation: c))
        try ledger.mark(job.key, .sending)
        let reloaded = try DeliveryLedger(store: store)
        XCTAssertEqual(reloaded.records[job.key]?.state, .unknown)
        XCTAssertNil(try reloaded.reserveExpiredCard(recordID: "original", conversation: c, now: deadline.addingTimeInterval(1)))
        let content = try AICardReply.statusContent(ref, status: "已过期，未执行任务。")
        XCTAssertTrue(content.contains("已过期")); XCTAssertFalse(content.contains("dws_assistant_submit"))
        XCTAssertFalse(content.contains("Countdown"))
    }

    func testSubscriptionAndTerminalUpdatesStayInOriginalAccountAndCard() throws {
        var config = AssistantConfig(); config.executablePaths["dws"] = "/bin/echo"
        let c = conversation(), ref = try reference(conversation())
        let listener = try Commands.cardActions(profile: c.profile, config: config)
        XCTAssertTrue(listener.streaming); XCTAssertEqual(listener.timeout, 0)
        XCTAssertTrue(listener.arguments.contains("user_card_action_triggered"))
        XCTAssertTrue(listener.arguments.contains(c.profile)); XCTAssertFalse(listener.arguments.contains("--group"))
        let content = try AICardReply.statusContent(ref, status: "已取消")
        let update = try Commands.updateCard(ref, content: content, config: config)
        XCTAssertTrue(update.arguments.contains(ref.bizID)); XCTAssertTrue(update.arguments.contains("FINISH"))
        XCTAssertFalse(update.arguments.contains("send-a2ui-card"))
        XCTAssertFalse(content.contains("createSurface")); XCTAssertFalse(content.contains("dws_assistant_submit"))
    }
}
