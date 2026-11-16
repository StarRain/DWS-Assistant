import XCTest
@testable import DashboardCore

final class CardSubmissionTests: XCTestCase {
    private func question(_ kind: String, required: Bool = true) -> [String: Any] {
        var result: [String: Any] = ["id": kind, "label": kind, "type": kind, "required": required]
        if kind != "text" {
            result["options"] = [["id": "debug", "label": "Debug"], ["id": "release", "label": "Release"]]
        }
        return result
    }

    private func card(_ questions: [[String: Any]]) throws -> (AICardReply, Conversation, AICardReference) {
        var conversation = Conversation()
        conversation.profile = "corp:user"; conversation.stableID = "cid-submit"
        conversation.listen = true; conversation.autoReply = true; conversation.replyFormat = .aiCard
        let data = try JSONSerialization.data(withJSONObject: ["kind": "dws_interaction", "text": "请补充任务信息", "questions": questions])
        let card = try AICardReply(text: String(decoding: data, as: UTF8.self), key: "submit-test", conversation: conversation)
        var reference = card.pendingReference(conversation: conversation); reference.bizID = "card-submit"
        return (card, conversation, reference)
    }

    private func components(_ card: AICardReply) throws -> [[String: Any]] {
        let messages = try JSONDecoder().decode([String].self, from: Data(card.creationContent.utf8))
        return try XCTUnwrap(try messages.compactMap { message in
            let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
            return (object?["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]]
        }.first)
    }

    // Build the native callback using the action actually emitted in the card.
    // Input values stand in for DingTalk's local /answers model at click time.
    private func event(_ card: AICardReply, reference: AICardReference, answers: [String: Any], action: String = "submit") throws -> CardActionEvent {
        let button = try XCTUnwrap(try components(card).first { $0["id"] as? String == action })
        var event = try XCTUnwrap((button["action"] as? [String: Any])?["event"] as? [String: Any])
        var context = try XCTUnwrap(event["context"] as? [String: Any])
        if action == "submit" { context["answers"] = answers }
        event["context"] = context; event["surfaceId"] = reference.surfaceID; event["sourceComponentId"] = action
        let body: [String: Any] = ["a2uiEvent": ["action": event], "bizInfoDTO": ["bizId": reference.bizID],
            "operatorDTO": ["openDingTalkId": "current-user"],
            "conversationContextDTO": ["openConversationId": reference.target],
            "triggerTimestamp": Int64(Date().timeIntervalSince1970 * 1_000)]
        let data = try JSONSerialization.data(withJSONObject: ["type": "user_card_action_triggered", "event_id": UUID().uuidString,
            "payload": ["body": body]])
        return try CardActionEvent(line: String(decoding: data, as: UTF8.self))
    }

    func testAllFormTypesHaveOneReachablePrimaryActionWithClickTimeValidation() throws {
        let forms = [[], [question("text")], [question("single")], [question("multiple")],
            [question("text"), question("single"), question("multiple", required: false)], [question("text", required: false)]]
        for questions in forms {
            let (card, _, _) = try card(questions)
            let components = try components(card)
            let buttons = components.filter { $0["component"] as? String == "Button" }
            XCTAssertEqual(buttons.count, 2, "Do not swap a permanently disabled clone with the real action")
            let submit = try XCTUnwrap(buttons.first { $0["id"] as? String == "submit" })
            XCTAssertEqual(submit["variant"] as? String, "primary")
            for button in buttons {
                XCTAssertNil(button["visible"], "A click must not depend on visibility being recomputed after local edits")
                XCTAssertNotEqual(button["disabled"] as? Bool, true)
            }
            let actions = try XCTUnwrap(components.first { $0["id"] as? String == "actions" })
            XCTAssertEqual(actions["children"] as? [String], ["cancel", "submit"])
            let checks = submit["checks"] as? [[String: Any]] ?? []
            XCTAssertEqual(checks.count, questions.filter { $0["required"] as? Bool == true }.count)
            for check in checks {
                let condition = try XCTUnwrap(check["condition"] as? [String: Any])
                let args = try XCTUnwrap(condition["args"] as? [String: Any])
                let path = try XCTUnwrap((args["value"] as? [String: String])?["path"])
                XCTAssertTrue(components.contains { ($0["value"] as? [String: String])?["path"] == path }, "Validate the actual input writeback path")
                if let pattern = args["pattern"] as? String {
                    let regex = try NSRegularExpression(pattern: pattern)
                    for text in ["打包", "\n打包\n并通知", "  hello  "] {
                        let range = NSRange(text.startIndex..., in: text)
                        XCTAssertEqual(regex.firstMatch(in: text, range: range)?.range, range)
                    }
                    for text in ["", " \t\n"] {
                        XCTAssertNil(regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
                    }
                }
            }
            XCTAssertNil(buttons.first { $0["id"] as? String == "cancel" }?["checks"])
        }
    }

    func testInvalidSubmissionsPreserveFormAndCorrectedInputIsClaimedOnlyOnce() throws {
        for kind in ["text", "single", "multiple"] {
            let (card, conversation, reference) = try card([question(kind)])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-submit-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let ledger = try DeliveryLedger(store: JSONStore(directory: directory))
            XCTAssertTrue(try ledger.reserve("original", route: conversation.id.uuidString))
            try ledger.attachCard(reference, to: "original"); try ledger.mark("original", .accepted)
            let invalid: [[String: Any]] = kind == "text"
                ? [[:], ["custom": ""], ["custom": " \n\t"], ["custom": String(repeating: "a", count: 2_001)]]
                : [[:], ["selected": [String]()], ["selected": ["unknown"]], ["selected": ["release", "release"]]]
            for value in invalid {
                let callback = try event(card, reference: reference, answers: [kind: value])
                XCTAssertThrowsError(try ledger.reserveCardAction(callback, recordID: "original", conversation: conversation, currentSenderID: "current-user"))
                XCTAssertEqual(ledger.records.count, 1)
                XCTAssertEqual(ledger.records["original"]?.card?.interaction?.consumed, false)
            }
            let value: [String: Any] = kind == "text" ? ["custom": "打包\n并通知"] : ["selected": kind == "single" ? ["release"] : ["debug", "release"]]
            let callback = try event(card, reference: reference, answers: [kind: value])
            let job = try XCTUnwrap(ledger.reserveCardAction(callback, recordID: "original", conversation: conversation, currentSenderID: "current-user"))
            XCTAssertEqual(job.action, "submit")
            XCTAssertTrue(job.submission.contains(kind == "text" ? "打包" : "Release"))
            XCTAssertNil(try ledger.reserveCardAction(callback, recordID: "original", conversation: conversation, currentSenderID: "current-user"))
        }
    }

    func testOptionalInputConfirmationAndCancelCanSubmitWithoutAnswers() throws {
        for questions in [[], [question("text", required: false), question("multiple", required: false)]] {
            let (card, conversation, reference) = try card(questions)
            let callback = try event(card, reference: reference, answers: [:])
            XCTAssertNoThrow(try callback.validate(reference: reference, conversation: conversation, currentSenderID: "current-user"))
        }
        let (card, conversation, reference) = try card([question("text"), question("single")])
        let cancel = try event(card, reference: reference, answers: [:], action: "cancel")
        XCTAssertEqual(try cancel.validate(reference: reference, conversation: conversation, currentSenderID: "current-user"), "已取消")
    }
}
