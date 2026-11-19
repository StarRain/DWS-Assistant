import XCTest
@testable import AssistantCore

@MainActor final class ImageTests: XCTestCase {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-images-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }
    func testCacheReservationsEnforceTotalLimitAndCleanCrashResidue() throws {
        let dir = try directory()
        let old = dir.appendingPathComponent("turn-stale")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 1024).write(to: old.appendingPathComponent("partial"))
        let cache = try ImageCache(directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        let lease = try cache.reserve(count: 4)
        XCTAssertEqual(cache.reservedBytes, ImageCache.maximumCacheBytes)
        XCTAssertThrowsError(try cache.reserve(count: 1))
        XCTAssertThrowsError(try cache.reserve(count: 5))
        try cache.release(lease)
        XCTAssertEqual(cache.reservedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lease.directory.path))
    }
    func testDownloadLimitAppliesDuringWriteWithoutTrustingMetadata() async throws {
        let dir = try directory()
        let cli = dir.appendingPathComponent("mock-dws")
        try "#!/bin/bash\nset -e\n/bin/dd if=/dev/zero of=source-0.bin bs=1048576 count=12 2>/dev/null\n".write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        var config = AssistantConfig(); config.executablePaths["dws"] = cli.path
        let resource = ImageResource(type: "mediaId", id: "image", messageID: "message", conversationID: "chat")
        let result = try await ProcessRunner.run(Commands.downloadImage(resource, profile: "corp:user", directory: dir, index: 0, config: config))
        XCTAssertNotEqual(result.status, 0)
        let bytes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("source-0.bin").path)[.size] as! NSNumber
        XCTAssertLessThanOrEqual(bytes.intValue, ImageCache.maximumImageBytes)
    }
    func testImageMetadataMustBelongToExactMessageAndConversation() throws {
        let event = try IMEvent(line: #"{"message_id":"m","conversation_id":"c","content":"[图片消息](mediaId=untrusted)"}"#)
        let resource: [String: Any] = ["type": "mediaId", "resourceId": "verified", "contentType": "image",
            "download": ["ready": true, "arguments": ["message-id": "m", "open-conversation-id": "c"]]]
        func result(_ conversation: String, _ refs: [[String: Any]]) throws -> CommandResult {
            let object: [String: Any] = ["messagesComplete": true, "messages": [["messageId": "m", "conversationId": conversation, "messageType": "image", "resourceRefs": refs]]]
            return CommandResult(status: 0, stdout: String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self), stderr: "")
        }
        XCTAssertEqual(try IncomingImages.resources(result("c", [resource, resource]), event: event).map(\.id), ["verified"])
        XCTAssertThrowsError(try IncomingImages.resources(result("other", [resource]), event: event))
        var foreign = resource; foreign["download"] = ["ready": true, "arguments": ["message-id": "other", "open-conversation-id": "c"]]
        XCTAssertThrowsError(try IncomingImages.resources(result("c", [foreign]), event: event))
    }
    func testImageCacheRejectsEscapingAndLinkedFiles() throws {
        let dir = try directory(), cache = try ImageCache(directory: directory())
        let lease = try cache.reserve(count: 1)
        defer { try? cache.release(lease) }
        let outside = dir.appendingPathComponent("outside.png")
        try Data([1,2,3]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: lease.directory.appendingPathComponent("source.bin"), withDestinationURL: outside)
        let resource = ImageResource(type: "mediaId", id: "image", messageID: "m", conversationID: "c")
        let result = CommandResult(status: 0, stdout: #"{"resourceId":"image","localPath":"source.bin"}"#, stderr: "")
        XCTAssertThrowsError(try cache.image(from: result, resource: resource, index: 0, lease: lease))
        XCTAssertEqual(try Data(contentsOf: outside), Data([1,2,3]))
    }
    func testTextDoesNotFetchMediaButSameChatQuotedImagesDo() throws {
        let text = try IMEvent(line: #"{"message_id":"m","conversation_id":"c","content":"你好"}"#)
        XCTAssertTrue(text.imageMessageIDs.isEmpty)
        let quoted = try IMEvent(line: #"{"message_id":"m","conversation_id":"c","content":"看这张图","quoted_message":{"message_id":"quoted","conversation_id":"c","content":"[图片消息]"}}"#)
        XCTAssertEqual(quoted.imageMessageIDs, ["quoted"])
        let foreign = try IMEvent(line: #"{"message_id":"m","conversation_id":"c","content":"看这张图","quoted_message":{"message_id":"quoted","conversation_id":"other","content":"[图片消息]"}}"#)
        XCTAssertTrue(foreign.imageMessageIDs.isEmpty)
    }
    func testEmptyMessagesAreIgnoredWhileUnicodeEmojiRemainText() throws {
        var conversation = Conversation()
        conversation.profile = "corp:user"; conversation.stableID = "c"
        conversation.listen = true; conversation.autoReply = true; conversation.trigger = .all
        func event(_ content: Any?) throws -> IMEvent {
            var object: [String: Any] = ["type": "user_im_message_receive_group", "message_id": "m",
                "conversation_id": "c", "sender_open_dingtalk_id": "other"]
            object["content"] = content
            return try IMEvent(line: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
        }
        for content in [nil, NSNull(), "", " \n\t"] as [Any?] {
            let empty = try event(content)
            XCTAssertTrue(empty.imageMessageIDs.isEmpty)
            XCTAssertFalse(EventRouting.shouldReply(empty, profile: "corp:user", conversation: conversation, currentSenderID: "self"))
        }
        for content in ["😂👍", "👨‍👩‍👧‍👦", "[微笑]", "收到👍"] {
            let text = try event(content)
            XCTAssertEqual(text.content, content)
            XCTAssertTrue(text.imageMessageIDs.isEmpty)
            XCTAssertTrue(EventRouting.shouldReply(text, profile: "corp:user", conversation: conversation, currentSenderID: "self"))
        }
        let emptyQuote = try IMEvent(line: #"{"message_id":"m","conversation_id":"c","content":"回复表情","quoted_message":{"message_id":"sticker","conversation_id":"c","content":""}}"#)
        XCTAssertTrue(emptyQuote.imageMessageIDs.isEmpty)
    }
    func testMessageReadDenialExplainsUnavailableImagesWithoutExposingPayload() throws {
        let event = try IMEvent(line: #"{"message_id":"m","conversation_id":"c","content":"[图片消息]"}"#)
        let denial = #"{"success":false,"code":"PAT_ORG_POLICY_DENIED","data":{"scope":"chat.message:list","reasonCode":"COMMAND_INACTIVE","clientSecret":"private-test-value","hint":"请联系组织管理员放开 scope"}}"#
        for result in [CommandResult(status: 1, stdout: "", stderr: denial),
                       CommandResult(status: 1, stdout: "", stderr: "diagnostic line\n" + denial + "\n"),
                       CommandResult(status: 0, stdout: denial, stderr: "")] {
            XCTAssertThrowsError(try IncomingImages.resources(result, event: event)) { error in
                XCTAssertEqual(error as? IncomingImageError, .messageReadDenied)
                XCTAssertTrue(error.localizedDescription.contains("请改用文字描述"))
                XCTAssertFalse(error.localizedDescription.contains("private-test-value"))
                XCTAssertFalse(error.localizedDescription.contains("管理员"))
            }
        }
        for unrelated in [denial.replacingOccurrences(of: "chat.message:list", with: "chat.message:send"),
                          denial.replacingOccurrences(of: "PAT_ORG_POLICY_DENIED", with: "PAT_AUTH_REQUIRED")] {
            XCTAssertThrowsError(try IncomingImages.resources(CommandResult(status: 1, stdout: "", stderr: unrelated), event: event)) { error in
                XCTAssertNil(error as? IncomingImageError)
            }
        }
    }
    func testOutgoingGuardSurvivesRestartAndDoesNotMatchOtherRoutes() throws {
        let store = try JSONStore(directory: directory()), ledger = try DeliveryLedger(store: store)
        var c = Conversation(); c.profile = "corp:user"; c.stableID = "c"
        _ = try ledger.reserve("key", route: c.id.uuidString)
        try ledger.prepareReplyEcho("answer", conversation: c, key: "key")
        try ledger.rememberSentMessages(CommandResult(status: 0, stdout: #"{"openMessageId":"sent-id"}"#, stderr: ""), conversation: c, key: "key")
        let reopened = try DeliveryLedger(store: store)
        let echo = try IMEvent(line: #"{"message_id":"sent-id","content":"transformed"}"#)
        XCTAssertTrue(reopened.isReplyEcho(echo, conversation: c))
        let body = try IMEvent(line: #"{"message_id":"new-id","content":"answer"}"#)
        XCTAssertTrue(reopened.isReplyEcho(body, conversation: c))
        c.stableID = "other"
        XCTAssertFalse(reopened.isReplyEcho(echo, conversation: c)); XCTAssertFalse(reopened.isReplyEcho(body, conversation: c))
    }
}
