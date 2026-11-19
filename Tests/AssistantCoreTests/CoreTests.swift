import XCTest
@testable import AssistantCore

final class CoreTests: XCTestCase {
    func testCurrentAccountComesFromAuthenticatedStatusOnly() {
        let status: [String: Any] = ["authenticated": true, "corp_id": "corp", "user_id": "user", "corp_name": "组织", "user_name": "用户"]
        XCTAssertEqual(JSONOutput.currentProfile(status), ProfileSummary(id: "corp:user", name: "用户", organization: "组织"))
        var loggedOut = status; loggedOut["authenticated"] = false
        XCTAssertNil(JSONOutput.currentProfile(loggedOut))
        var incomplete = status; incomplete.removeValue(forKey: "user_id")
        XCTAssertNil(JSONOutput.currentProfile(incomplete))
    }

    func conversation(kind: ConversationKind = .group) -> Conversation {
        var c = Conversation(); c.kind = kind; c.stableID = kind == .group ? "cid-stable" : "open-user"; c.profile = "corp:user"; c.listen = true; c.autoReply = true; c.trigger = .mentioned; c.agent.workdir = "/tmp"
        return c
    }
    func event(type: String = "user_im_message_receive_group", message: String = "m1", target: String = "cid-stable", sender: String = "open-user", content: String = "你好") throws -> IMEvent {
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "message_id": message, "conversation_id": target, "sender_open_dingtalk_id": sender, "content": content])
        return try IMEvent(line: String(decoding: data, as: UTF8.self))
    }
    func temporaryStore() throws -> JSONStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dashboard-tests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try JSONStore(directory: url)
    }
    func testOnlyRealAtEventsTriggerMentionReply() throws {
        let c = conversation()
        XCTAssertFalse(EventRouting.shouldReply(try event(content: "@我的名字"), profile: c.profile, conversation: c, currentSenderID: "self-open"))
        XCTAssertTrue(EventRouting.shouldReply(try event(type: "user_im_message_receive_at"), profile: c.profile, conversation: c, currentSenderID: "self-open"))
        XCTAssertFalse(EventRouting.shouldReply(try event(type: "user_im_message_reaction_group"), profile: c.profile, conversation: c, currentSenderID: "self-open"))
    }
    func testReplyTriggersCheckVerifiedSenderAndRealMention() throws {
        for trigger in ReplyTrigger.allCases {
            var c = conversation(); c.trigger = trigger
            let cases: [(String, String, Bool)] = [
                ("user_im_message_receive_group", "open-user", trigger == .all),
                ("user_im_message_receive_at", "open-user", trigger != .selfMentioned),
                ("user_im_message_receive_at", "user", trigger != .selfMentioned),
                ("user_im_message_receive_group", "self-open", false),
                ("user_im_message_receive_at", "self-open", true),
                ("user_im_message_receive_at", "", false)
            ]
            for (type, sender, expected) in cases {
                let e = try event(type: type, sender: sender, content: "@自己 请处理")
                XCTAssertEqual(EventRouting.shouldReply(e, profile: c.profile, conversation: c, currentSenderID: "self-open"), expected, "\(trigger) / \(type) / \(sender)")
                XCTAssertFalse(EventRouting.shouldReply(e, profile: c.profile, conversation: c, currentSenderID: ""))
            }
        }
        var contact = conversation(kind: .contact); contact.trigger = .selfMentioned
        XCTAssertTrue(EventRouting.shouldReply(try event(type: "user_im_message_receive_o2o"), profile: contact.profile, conversation: contact, currentSenderID: "self-open"), "Group mention preferences do not disable direct replies")
    }
    func testReplyTriggerDefaultsAndSavedChoicesSurviveDecoding() throws {
        var c = conversation()
        for trigger in ReplyTrigger.allCases {
            c.trigger = trigger
            XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c)).trigger, trigger)
        }
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        row.removeValue(forKey: "trigger")
        XCTAssertEqual(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: row)).trigger, .selfMentioned)
        row["trigger"] = "unrecognized"
        XCTAssertThrowsError(try JSONDecoder().decode(Conversation.self, from: JSONSerialization.data(withJSONObject: row)))
    }
    func testPausedAndObserveOnlyNeverReply() throws {
        var c = conversation(); c.trigger = .all
        XCTAssertTrue(EventRouting.shouldReply(try event(), profile: c.profile, conversation: c, currentSenderID: "self-open"))
        c.autoReply = false
        XCTAssertTrue(EventRouting.matches(try event(), profile: c.profile, conversation: c))
        XCTAssertFalse(EventRouting.shouldReply(try event(), profile: c.profile, conversation: c, currentSenderID: "self-open"))
        c.listen = false; c.autoReply = true
        XCTAssertFalse(EventRouting.matches(try event(), profile: c.profile, conversation: c))
    }
    func testContactNeverConsumesSameSendersGroupMessage() throws {
        let c = conversation(kind: .contact)
        XCTAssertFalse(EventRouting.matches(try event(), profile: c.profile, conversation: c))
        XCTAssertFalse(EventRouting.matches(try event(type: "user_im_message_receive_sender"), profile: c.profile, conversation: c))
        XCTAssertTrue(EventRouting.matches(try event(type: "user_im_message_receive_o2o"), profile: c.profile, conversation: c))
    }
    func testOtherProfileAndTargetCannotRoute() throws {
        let c = conversation()
        XCTAssertFalse(EventRouting.matches(try event(), profile: "other:user", conversation: c))
        XCTAssertFalse(EventRouting.matches(try event(target: "cid-wrong"), profile: c.profile, conversation: c))
        XCTAssertFalse(EventRouting.matches(try event(message: ""), profile: c.profile, conversation: c))
    }
    func testIndependentIdentitiesAndPersistentUnknownDelivery() throws {
        let store = try temporaryStore()
        let ledger = try DeliveryLedger(store: store)
        let personal = DeliveryLedger.key(identity: "personal", profile: "p", target: "c", messageID: "m")
        let other = DeliveryLedger.key(identity: "personal", profile: "other", target: "c", messageID: "m")
        XCTAssertNotEqual(personal, other)
        XCTAssertTrue(try ledger.reserve(personal, route: "route"))
        XCTAssertTrue(try ledger.reserve(other, route: "route"))
        try ledger.mark(personal, .sending)
        let reopened = try DeliveryLedger(store: store)
        XCTAssertEqual(reopened.records[personal]?.state, .unknown)
        XCTAssertFalse(try reopened.reserve(personal, route: "route"))
    }
    func testConfigurationIsSafeByDefaultAndStoresNoSecrets() throws {
        let c = Conversation(); XCTAssertFalse(c.listen); XCTAssertFalse(c.autoReply); XCTAssertTrue(c.showAITag); XCTAssertEqual(c.trigger, .selfMentioned)
        let json = String(decoding: try JSONEncoder().encode(AssistantConfig()), as: UTF8.self)
        XCTAssertFalse(json.contains("secret")); XCTAssertFalse(json.contains("token"))
    }
    func testDuplicateStableRoutesRejected() throws {
        var config = AssistantConfig(); let c = conversation(); config.conversations = [c]
        XCTAssertNoThrow(try Validation.configuration(config))
        var duplicate = c; duplicate.id = UUID(); config.conversations.append(duplicate)
        XCTAssertThrowsError(try Validation.configuration(config))
    }
    func testLegacyConfigKeepsPersonalSettingsAndDropsRobotFields() throws {
        let original = conversation()
        var row = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        row.removeValue(forKey: "showAITag"); row.removeValue(forKey: "showReplyStatus")
        row["botEnabled"] = true; row["webhookConfigured"] = true
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "conversations": [row], "bots": [["legacy": true]], "executablePaths": [:]])
        let decoded = try JSONDecoder().decode(AssistantConfig.self, from: data)
        XCTAssertEqual(decoded.conversations, [original]); XCTAssertEqual(decoded.appearance, .system)
        let encoded = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        XCTAssertFalse(encoded.contains("bot")); XCTAssertFalse(encoded.contains("webhook"))
    }
    func testAITagAndFeedbackPreferencesPersistAndDriveSend() throws {
        var config = AssistantConfig(); config.executablePaths["dws"] = "/bin/echo"
        for kind in ConversationKind.allCases {
            for enabled in [true, false] {
                var c = conversation(kind: kind); c.showAITag = enabled; c.showReplyStatus = enabled
                let decoded = try JSONDecoder().decode(Conversation.self, from: JSONEncoder().encode(c))
                XCTAssertEqual(decoded, c)
                let args = try Commands.send(decoded, text: "answer", key: "key", config: config).arguments
                XCTAssertTrue(args.contains("--ai-tag=\(enabled)"))
            }
        }
    }
    func testReactionTargetsOriginalMessageAndRejectsUnrelatedEvents() throws {
        var config = AssistantConfig(); config.executablePaths["dws"] = "/bin/echo"
        let c = conversation(kind: .contact)
        let original = try event(type: "user_im_message_receive_o2o", target: "cid-private")
        let spec = try Commands.reaction(.processing, event: original, conversation: c, currentSenderID: "self-open", config: config)
        XCTAssertTrue(spec.arguments.contains("cid-private")); XCTAssertFalse(spec.arguments.contains(c.stableID))
        XCTAssertTrue(spec.arguments.contains("m1")); XCTAssertTrue(spec.arguments.contains("思考"))
        XCTAssertThrowsError(try Commands.reaction(.completed, event: event(sender: "other"), conversation: c, currentSenderID: "self-open", config: config))
        XCTAssertThrowsError(try Commands.reaction(.completed, event: event(type: "user_im_message_receive_o2o", target: ""), conversation: c, currentSenderID: "self-open", config: config))
    }
    func testDataMigrationPreservesLedgerAndLeavesExistingDestinationAlone() throws {
        let parent = try temporaryStore().directory
        let old = parent.appendingPathComponent("old"), new = parent.appendingPathComponent("new")
        let store = try JSONStore(directory: old)
        var config = AssistantConfig(); config.conversations = [conversation()]; config.appearance = .dark
        try store.save(config, to: "config.json")
        let ledger = try DeliveryLedger(store: store); XCTAssertTrue(try ledger.reserve("dedup", route: "route")); try ledger.mark("dedup", .delivered)
        try AssistantPaths.migrateLegacy(from: old, to: new)
        let migrated = try JSONStore(directory: new)
        XCTAssertEqual(try migrated.load("config.json", as: AssistantConfig.self), config)
        XCTAssertEqual(try DeliveryLedger(store: migrated).records["dedup"]?.state, .delivered)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.appendingPathComponent("config.json").path))
        try migrated.save(AssistantConfig(), to: "config.json")
        try AssistantPaths.migrateLegacy(from: old, to: new)
        XCTAssertEqual(try migrated.load("config.json", as: AssistantConfig.self), AssistantConfig())
    }
    func testReasoningOverrideKeepsCodexScopeAndLeavesDefaultEncodingStable() throws {
        var settings = AgentSettings(); settings.workdir = "/tmp"
        let original = try Commands.officialAgent(settings, prompt: "hello", route: "r", bridgePath: "/bin/echo", stateDirectory: "/tmp/state", config: AssistantConfig())
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(settings), as: UTF8.self).contains("reasoningEffort"))
        settings.reasoningEffort = .low
        let fast = try Commands.officialAgent(settings, prompt: "hello", route: "r", bridgePath: "/bin/echo", stateDirectory: "/tmp/state", config: AssistantConfig())
        let a = try JSONSerialization.jsonObject(with: Data(original.stdin!.utf8)) as! [String: Any]
        let b = try JSONSerialization.jsonObject(with: Data(fast.stdin!.utf8)) as! [String: Any]
        XCTAssertEqual(b["reasoning_effort"] as? String, "low")
        XCTAssertEqual(a["scope_id"] as? String, b["scope_id"] as? String)
        XCTAssertNil(b["legacy_scope_id"])
    }
    func testPersonalUsesOfficialBridgeWithSeparateScopes() throws {
        var settings = AgentSettings(); settings.workdir = "/tmp"
        let config = AssistantConfig()
        let a = try Commands.officialAgent(settings, prompt: "hello", route: "corp:user|a", bridgePath: "/bin/echo", stateDirectory: "/tmp/state", config: config)
        let b = try Commands.officialAgent(settings, prompt: "hello", route: "corp:user|b", bridgePath: "/bin/echo", stateDirectory: "/tmp/state", config: config)
        XCTAssertEqual(a.executable, "/bin/echo"); XCTAssertTrue(a.arguments.isEmpty)
        let ja = try JSONSerialization.jsonObject(with: Data(a.stdin!.utf8)) as! [String: Any]
        let jb = try JSONSerialization.jsonObject(with: Data(b.stdin!.utf8)) as! [String: Any]
        XCTAssertNotEqual(ja["scope_id"] as? String, jb["scope_id"] as? String)
        XCTAssertEqual(ja["full_permission"] as? Bool, false)
    }
    func testBodyOnlyOnStdinAndStableTarget() throws {
        var c = conversation(); c.name = "不同的显示名"
        var config = AssistantConfig(); config.executablePaths["dws"] = "/bin/echo"
        let body = "$(touch /tmp/no) `whoami` ; --group other"
        let spec = try Commands.send(c, text: body, key: "key", config: config)
        XCTAssertEqual(spec.stdin, body); XCTAssertFalse(spec.arguments.contains(body)); XCTAssertTrue(spec.arguments.contains(c.stableID)); XCTAssertFalse(spec.arguments.contains(c.name))
    }
    func testUnknownReceiptIsNotSuccess() {
        XCTAssertFalse(JSONOutput.delivered(CommandResult(status: 0, stdout: "{\"success\":true}", stderr: "")))
        XCTAssertTrue(JSONOutput.delivered(CommandResult(status: 0, stdout: "{\"data\":{\"deliveryStatus\":\"delivered\"}}", stderr: "")))
        XCTAssertFalse(JSONOutput.delivered(CommandResult(status: 1, stdout: "{\"deliveryStatus\":\"delivered\"}", stderr: "failed")))
    }
    func testFinalAnswerDoesNotUseProgressOrErrors() throws {
        XCTAssertEqual(try Commands.finalAnswer(CommandResult(status: 0, stdout: "{\"result\":\"最终回复\"}", stderr: "progress"), engine: .codex), "最终回复")
        XCTAssertThrowsError(try Commands.finalAnswer(CommandResult(status: 0, stdout: "{\"result\":\"failed\",\"is_error\":true}", stderr: ""), engine: .claude))
    }
    func testDiscoveryDeduplicatesAndKeepsIncompleteCursor() throws {
        let json = #"{"groups":[{"conversationId":"a","name":"A"},{"conversationId":"a","name":"B"}],"complete":false,"hasMore":true,"nextCursor":"next","stopReason":"single_page"}"#
        let page = try JSONOutput.groups(CommandResult(status: 0, stdout: json, stderr: ""))
        XCTAssertEqual(page.items.count, 1); XCTAssertFalse(page.complete); XCTAssertEqual(page.nextCursor, "next")
    }
    func testRedaction() {
        let raw = #"url=https://oapi.dingtalk.com/robot/send?access_token=abc&sign=xyz secret=TOPSECRET {"clientSecret":"other-secret"} Authorization: Bearer abcd"#
        let clean = Redaction.clean(raw)
        for value in ["TOPSECRET", "other-secret", "abcd", "access_token=abc"] { XCTAssertFalse(clean.contains(value)) }
    }
    func testProcessUsesLiteralArgumentsAndStdin() async throws {
        let spec = CommandSpec(executable: "/usr/bin/printf", arguments: ["%s", "$(echo unsafe); hello with spaces"])
        let result = try await ProcessRunner.run(spec)
        XCTAssertEqual(result.stdout, "$(echo unsafe); hello with spaces")
        let piped = try await ProcessRunner.run(CommandSpec(executable: "/bin/cat", arguments: [], stdin: "中文\n正文"))
        XCTAssertEqual(piped.stdout, "中文\n正文")
    }
    func testProcessCancellation() async throws {
        let job = ProcessJob(CommandSpec(executable: "/bin/sleep", arguments: ["30"], timeout: 30))
        let task = Task { try await job.value() }
        try await Task.sleep(for: .milliseconds(100)); task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertFalse(job.isRunning) }
    }
}
