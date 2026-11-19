import XCTest
@testable import AssistantCore

final class ReplyLoopTests: XCTestCase {
    func testCardSummaryEchoesRemainSuppressedAcrossRenameAndRestart() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("card-summary-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONStore(directory: directory), ledger = try DeliveryLedger(store: store)
        var conversation = Conversation()
        conversation.profile = "corp:user"; conversation.stableID = "group-one"; conversation.replyFormat = .aiCard
        XCTAssertTrue(try ledger.reserve("reply", route: conversation.id.uuidString))
        try ledger.prepareReplyEcho("answer", conversation: conversation, key: "reply")
        let reopened = try DeliveryLedger(store: store)
        for summary in [AICardReply.summary, "AI 助手回复"] {
            let data = try JSONSerialization.data(withJSONObject: ["message_id": UUID().uuidString, "content": summary])
            let event = try IMEvent(line: String(decoding: data, as: UTF8.self))
            XCTAssertTrue(reopened.isReplyEcho(event, conversation: conversation))
            var other = conversation; other.stableID = "group-two"
            XCTAssertFalse(reopened.isReplyEcho(event, conversation: other))
        }
    }

    private func result(_ object: [String: Any], status: Int32 = 0) throws -> CommandResult {
        CommandResult(status: status, stdout: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), stderr: "")
    }

    func testSelfIdentityRequiresExactUserIDAndUniqueOpenID() throws {
        let selfRow = ["userId": "user", "openDingTalkId": "self-open", "name": "相同昵称"]
        let otherRow = ["userId": "other", "openDingTalkId": "other-open", "name": "相同昵称"]
        let data: [String: Any] = ["success": true, "result": [otherRow, selfRow, selfRow]]
        XCTAssertEqual(try JSONOutput.selfSenderID(result(["data": data]), userID: "user"), "self-open")
        let text = String(decoding: try JSONSerialization.data(withJSONObject: data), as: UTF8.self)
        XCTAssertEqual(try JSONOutput.selfSenderID(result(["content": [["type": "text", "text": text]]]), userID: "user"), "self-open")
        XCTAssertEqual(try JSONOutput.selfSenderID(result(["result": ["user": ["openDingTalkId": "self-open"]]]), userID: "user"), "self-open")
        XCTAssertThrowsError(try JSONOutput.selfSenderID(result(["result": [otherRow]]), userID: "user"))
        XCTAssertThrowsError(try JSONOutput.selfSenderID(result(["result": [selfRow, ["userId": "user", "openDingTalkId": "ambiguous"]]]), userID: "user"))
        XCTAssertThrowsError(try JSONOutput.selfSenderID(result(["result": [["userId": "user"]]]), userID: "user"))
        XCTAssertThrowsError(try JSONOutput.selfSenderID(result(["result": [selfRow], "success": false]), userID: "user"))
        XCTAssertThrowsError(try JSONOutput.selfSenderID(result(["result": [selfRow]], status: 1), userID: "user"))
    }

    func testSelfIdentityLookupUsesAccountScopeAndUserIDNotName() throws {
        var config = AssistantConfig(); config.executablePaths["dws"] = "/bin/echo"
        let command = try Commands.selfIdentity(profile: "corp:user", config: config)
        XCTAssertEqual(command.arguments, ["contact", "user", "search", "--query", "user", "--profile", "corp:user", "--format", "json"])
        XCTAssertThrowsError(try Commands.selfIdentity(profile: "user", config: config))
    }

    func testSelfAndMissingSenderAreIgnoredWithoutMatchingContentOrNames() throws {
        func event(_ sender: String) throws -> IMEvent {
            try IMEvent(line: #"{"type":"user_im_message_receive_group","message_id":"new-id","sender":"同名用户","sender_open_dingtalk_id":"\#(sender)","content":"相同正文"}"#)
        }
        XCTAssertFalse(EventRouting.isIncoming(try event("self-open"), currentSenderID: "self-open"))
        XCTAssertFalse(EventRouting.isIncoming(try event(""), currentSenderID: "self-open"))
        XCTAssertFalse(EventRouting.isIncoming(try event("other-open"), currentSenderID: ""))
        XCTAssertTrue(EventRouting.isIncoming(try event("other-open"), currentSenderID: "self-open"))
        // The organization userId is not the openDingTalkId used in events.
        XCTAssertTrue(EventRouting.isIncoming(try event("user"), currentSenderID: "self-open"))
    }
}
