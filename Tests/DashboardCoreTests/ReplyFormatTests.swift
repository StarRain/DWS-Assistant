import XCTest
@testable import DashboardCore

final class ReplyFormatTests: XCTestCase {
    private func conversation(_ kind: ConversationKind = .group) -> Conversation {
        var value = Conversation(); value.kind = kind; value.profile = "corp:user"; value.stableID = kind == .group ? "cid-target" : "open-target"
        return value
    }

    func testLegacyConfigurationKeepsPlainTextAndFormatsPersist() throws {
        var value = conversation()
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        old.removeValue(forKey: "replyFormat")
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: old)).replyFormat, .text)
        for format in ReplyFormat.allCases {
            value.replyFormat = format
            XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(value)), value)
        }
    }

    func testSendFormatsKeepRecipientAndBodyBoundaries() throws {
        var config = DashboardConfig(); config.executablePaths["dws"] = "/bin/echo"
        let body = "# 答复\n`$(danger)`\n![附件](./private.png)"
        for kind in ConversationKind.allCases {
            for format in ReplyFormat.allCases {
                var c = conversation(kind); c.replyFormat = format; c.showAITag = false
                let spec = try Commands.send(c, text: body, key: "stable-key", config: config)
                XCTAssertTrue(spec.arguments.contains(c.stableID)); XCTAssertTrue(spec.arguments.contains(c.profile))
                XCTAssertFalse(spec.arguments.contains(body))
                if format == .aiCard {
                    XCTAssertTrue(spec.arguments.contains("send-a2ui-card"))
                    XCTAssertTrue(spec.arguments.contains(kind == .group ? "--conversation-id" : "--open-dingtalk-id"))
                    XCTAssertFalse(spec.arguments.contains("--idempotency-key"))
                    XCTAssertFalse(spec.arguments.contains("--ai-tag=false"))
                } else {
                    XCTAssertTrue(spec.arguments.contains(format == .markdown ? "--markdown" : "--text"))
                    XCTAssertTrue(spec.arguments.contains("--ai-tag=false")); XCTAssertTrue(spec.arguments.contains("--wait-delivery"))
                    XCTAssertEqual(spec.stdin, format == .markdown ? "# 答复\n`$(danger)`\n[附件](./private.png)" : body)
                }
            }
        }
    }

    func testCardKeepsAnswerAsTextAndFinishesSameSurfaceWithoutRecreating() throws {
        let answer = "## 回答\n```json\n{\"createSurface\":\"untrusted\"}\n```"
        let card = try AICardReply(text: answer, key: "key")
        let initial = try decode(card.creationContent), finish = try decode(card.finishContent)
        XCTAssertEqual(initial.count, 3); XCTAssertEqual(finish.count, 1)
        XCTAssertEqual((initial[0]["createSurface"] as? [String: Any])?["surfaceId"] as? String, card.surfaceID)
        let components = (initial[2]["updateComponents"] as? [String: Any])?["components"] as! [[String: Any]]
        let answerComponent = try XCTUnwrap(components.first { $0["id"] as? String == "answer" })
        XCTAssertEqual(answerComponent["content"] as? String, answer)
        XCTAssertTrue(components.allSatisfy { $0["action"] == nil })
        XCTAssertEqual(components.filter { $0["id"] as? String == "ai-attribution" }.count, 1)
        XCTAssertNil(finish[0]["createSurface"])
        let delta = finish[0]["updateDataModel"] as! [String: Any]
        XCTAssertEqual(delta["surfaceId"] as? String, card.surfaceID); XCTAssertEqual(delta["path"] as? String, "/status")
        XCTAssertEqual(try AICardReply(text: answer, key: "key").surfaceID, card.surfaceID)
    }

    func testCardRequiresServerBizIDAndExplicitAcceptance() throws {
        let card = try AICardReply(text: "回答", key: "key"), c = conversation()
        let created = receipt(#"{"ok":true,"data":{"success":true,"result":{"bizId":"server-biz"}}}"#)
        let reference = try card.reference(from: created, conversation: c)
        XCTAssertEqual(reference.bizID, "server-biz"); XCTAssertEqual(reference.profile, c.profile)
        XCTAssertFalse(JSONOutput.delivered(created))
        for invalid in [#"{"ok":true}"#, #"{"success":true,"bizCardId":"request-only"}"#, #"{"success":false,"result":{"bizId":"b"}}"#] {
            XCTAssertThrowsError(try card.reference(from: receipt(invalid), conversation: c))
        }
        XCTAssertTrue(try AICardReply.updateAccepted(receipt(#"{"data":{"success":true}}"#), reference: reference))
        XCTAssertFalse(try AICardReply.updateAccepted(receipt(#"{"ok":true}"#), reference: reference))
        XCTAssertThrowsError(try AICardReply.updateAccepted(receipt(#"{"success":true,"result":{"bizId":"other"}}"#), reference: reference))
    }

    func testCardReferenceSurvivesRestartAndCannotBeReservedAgain() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-ledger-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONStore(directory: directory), ledger = try DeliveryLedger(store: store)
        XCTAssertTrue(try ledger.reserve("key", route: "route"))
        let card = try AICardReply(text: "回答", key: "key")
        let reference = try card.reference(from: receipt(#"{"success":true,"result":{"bizId":"server-biz"}}"#), conversation: conversation())
        try ledger.attachCard(reference, to: "key"); try ledger.mark("key", .sending)
        let restored = try DeliveryLedger(store: store)
        XCTAssertEqual(restored.records["key"]?.card, reference); XCTAssertEqual(restored.records["key"]?.state, .unknown)
        XCTAssertFalse(try restored.reserve("key", route: "route"))
        var config = DashboardConfig(); config.executablePaths["dws"] = "/bin/echo"
        let finish = try Commands.finishCard(reference, config: config)
        XCTAssertTrue(finish.arguments.contains("server-biz")); XCTAssertTrue(finish.arguments.contains("FINISH"))
        XCTAssertEqual(finish.stdin, card.finishContent)
    }

    func testInitialProgressStreamsButInteractiveFollowupsKeepTransportFinished() throws {
        var config = DashboardConfig(); config.executablePaths["dws"] = "/bin/echo"
        let c = conversation()
        let initial = try AICardReply(text: "思考中…", key: "progress", processing: true)
        let initialReference = try initial.reference(from: receipt(#"{"success":true,"result":{"bizId":"server-biz"}}"#), conversation: c)
        XCTAssertTrue(try Commands.updateCard(initialReference, content: initial.replacementContent, processing: true, config: config).arguments.contains("INPUTTING"))

        let form = try AICardReply(text: #"{"kind":"dws_interaction","text":"请选择后继续","questions":[]}"#, key: "form", conversation: c, surfaceID: initial.surfaceID)
        let formReference = form.replacing(initialReference, conversation: c)
        // Persisted forms from earlier versions also have this information.
        let restored = try JSONDecoder().decode(AICardReference.self, from: JSONEncoder().encode(formReference))
        for reference in [formReference, restored] {
            for content in [try AICardReply.statusContent(reference, status: "处理中，请稍候…"),
                            try AICardReply.progressContent(reference, progress: .init())] {
                let update = try Commands.updateCard(reference, content: content, processing: true, config: config)
                XCTAssertTrue(update.arguments.contains("FINISH"))
                XCTAssertFalse(update.arguments.contains("INPUTTING"))
                XCTAssertTrue(update.arguments.contains(initialReference.bizID))
                XCTAssertTrue(update.arguments.contains(c.profile))
                XCTAssertEqual(update.stdin, content)
            }
        }
    }

    func testLateProcessingCardEchoStaysSuppressedAfterFinalUpdateAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-echo-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONStore(directory: directory), ledger = try DeliveryLedger(store: store)
        var c = conversation(); c.replyFormat = .aiCard
        XCTAssertTrue(try ledger.reserve("key", route: c.id.uuidString))
        try ledger.prepareReplyEcho("AI 正在处理…", conversation: c, key: "key")
        try ledger.prepareReplyEcho("最终答复", conversation: c, key: "key")
        let reopened = try DeliveryLedger(store: store)
        let delayed = try IMEvent(line: #"{"message_id":"late-placeholder","content":"AI 正在处理…"}"#)
        let final = try IMEvent(line: #"{"message_id":"late-final","content":"最终答复"}"#)
        XCTAssertTrue(reopened.isReplyEcho(delayed, conversation: c)); XCTAssertTrue(reopened.isReplyEcho(final, conversation: c))
        c.stableID = "other-group"
        XCTAssertFalse(reopened.isReplyEcho(delayed, conversation: c))
    }

    private func receipt(_ json: String) -> CommandResult { CommandResult(status: 0, stdout: json, stderr: "") }
    private func decode(_ content: String) throws -> [[String: Any]] {
        try JSONDecoder().decode([String].self, from: Data(content.utf8)).map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
}
