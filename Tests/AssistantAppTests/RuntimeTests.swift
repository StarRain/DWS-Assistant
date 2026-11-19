import XCTest
import Darwin
@testable import AssistantCore
@testable import DWSAssistant

@MainActor
final class RuntimeTests: XCTestCase {
    private func fixture(slowAI: Bool, format: ReplyFormat = .text) throws -> (AssistantModel, URL) {
        // XCTest bypasses App.init; match the app's handling of a child that
        // closes stdin while a cancellation or reply is in flight.
        signal(SIGPIPE, SIG_IGN)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let dws = dir.appendingPathComponent("dws")
        let gemini = dir.appendingPathComponent("gemini")
        let script = #"""
        #!/bin/bash
        base="$(cd "$(dirname "$0")" && pwd)"
        printf '%s\n' "$*" >> "$base/commands"
        if [[ "$1" == "event" && "$3" == "user_card_action_triggered" ]]; then
          echo card-listener >> "$base/card-listeners"
          echo '[event] ready subscribe_id=mock-card' >&2
          seen=0
          while true; do
            if [[ -f "$base/card-events.ndjson" ]]; then
              index=0
              while IFS= read -r line; do
                index=$((index+1))
                if (( index > seen )); then printf '%s\n' "$line"; fi
              done < "$base/card-events.ndjson"
              seen=$index
            fi
            /bin/sleep 0.02
          done
        elif [[ "$1" == "event" ]]; then
          echo listener >> "$base/listeners"
          echo '[event] ready subscribe_id=mock' >&2
          if [[ -f "$base/events.ndjson" ]]; then
            /bin/cat "$base/events.ndjson"
          else
          echo '{"type":"user_im_message_receive_group","message_id":"m1","conversation_id":"cid-test","sender_open_dingtalk_id":"sender","content":"hello"}'
          echo '{"type":"user_im_message_receive_group","message_id":"m1","conversation_id":"cid-test","sender_open_dingtalk_id":"sender","content":"duplicate"}'
          fi
          if [[ -f "$base/echoes.ndjson" ]]; then
            for ((i=0; i<100; i++)); do
              [[ -f "$base/sends" || -f "$base/card-creates" ]] && break
              /bin/sleep 0.02
            done
            /bin/cat "$base/echoes.ndjson"
          fi
          while IFS= read -r line; do :; done
        elif [[ "$1" == "contact" ]]; then
          printf '%s\n' "$*" >> "$base/identity-lookups"
          [[ -f "$base/identity-delay" ]] && /bin/sleep 1
          if [[ -f "$base/identity-result.json" ]]; then
            /bin/cat "$base/identity-result.json"
          else
            echo '{"success":true,"result":[{"userId":"user","openDingTalkId":"self-open"}]}'
          fi
        elif [[ "$2" == "message" && "$3" == "send-a2ui-card" ]]; then
          /bin/cat > "$base/card-create-body"
          echo create >> "$base/card-creates"
          /bin/rm -f "$base/card-stream-finished"
          echo '{"success":true,"result":{"bizId":"mock-card"}}'
        elif [[ "$2" == "message" && "$3" == "update-a2ui-card" ]]; then
          /bin/cat > "$base/card-update-body"
          echo update >> "$base/card-updates"
          arguments=("$@")
          flow=""
          for ((i=0; i<${#arguments[@]}-1; i++)); do
            [[ "${arguments[i]}" == "--flow-status" ]] && flow="${arguments[i+1]}"
          done
          printf '%s\n' "$flow" >> "$base/card-flow-statuses"
          if [[ -f "$base/enforce-finished-stream" && -f "$base/card-stream-finished" && "$flow" != "FINISH" ]]; then
            echo '{"error":{"message":"a2ui dws card update failed","server_error_code":"500136"}}'
            exit 1
          fi
          [[ -f "$base/card-update-failure" ]] && exit 1
          [[ "$flow" == "FINISH" ]] && /usr/bin/touch "$base/card-stream-finished"
          printf '{"success":true,"result":{"bizId":"mock-card","flowStatus":"%s"}}\n' "$flow"
        elif [[ "$2" == "+messages-send" ]]; then
          /bin/cat > "$base/sent-body"
          echo sent >> "$base/sends"
          echo '{"deliveryStatus":"delivered","openMessageId":"mock-sent"}'
        elif [[ "$2" == "+messages-mget" ]]; then
          echo read >> "$base/metadata-reads"
          if [[ -f "$base/image-details-error.json" ]]; then
            /bin/cat "$base/image-details-error.json" >&2
            exit 1
          fi
          echo '{}'
        elif [[ "$1" == "chat" ]]; then
          printf '%s\n' "$*" >> "$base/reactions"
          echo '{"success":true}'
        else
          echo '{}'
        fi
        """#
        try script.write(to: dws, atomically: true, encoding: .utf8)
        // Sleep process is short-lived and isolated; the real engines are never launched.
        try "#!/bin/bash\n/bin/cat >/dev/null\necho generated >> \"\(dir.path)/generations\"\n\(slowAI ? "/bin/sleep 1" : ":")\necho '{\"response\":\"mock answer\"}'\n".write(to: gemini, atomically: true, encoding: .utf8)
        for path in [dws, gemini] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
        let model = AssistantModel(directory: dir.appendingPathComponent("state"))
        model.profile = ProfileSummary(id: "corp:user", name: "测试账号", organization: "测试组织")
        model.accountOK = true
        var c = Conversation(); c.profile = "corp:user"; c.stableID = "cid-test"; c.listen = true; c.autoReply = true; c.trigger = .all; c.agent.engine = .gemini; c.agent.workdir = dir.path
        c.replyFormat = format
        var config = AssistantConfig(); config.setupCompleted = true; config.conversations = [c]; config.executablePaths = ["dws": dws.path, "gemini": gemini.path]
        try model.persist(config)
        return (model, dir)
    }

    private func writeEvents(_ events: [(String, String, String, String)], to file: URL) throws {
        let lines = try events.map { type, messageID, senderID, content in
            String(decoding: try JSONSerialization.data(withJSONObject: ["type": "user_im_message_receive_" + type,
                "message_id": messageID, "conversation_id": "cid-test", "sender_open_dingtalk_id": senderID, "content": content]), as: UTF8.self)
        }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func interactiveFixture() throws -> (AssistantModel, URL) {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        addTeardownBlock { _ = await model.stopAll() }
        let script = #"""
        #!/bin/bash
        base="$(cd "$(dirname "$0")" && pwd)"
        /bin/cat > "$base/agent-input"
        echo generated >> "$base/generations"
        [[ -f "$base/slow-followup" ]] && /bin/sleep 1
        /bin/cat "$base/ai-output.json"
        """#
        try script.write(to: dir.appendingPathComponent("gemini"), atomically: false, encoding: .utf8)
        let form = #"{"kind":"dws_interaction","text":"请选择构建类型，再确认继续。","submitLabel":"确认打包","questions":[{"id":"build","label":"构建类型","type":"single","options":[{"id":"debug","label":"Debug"},{"id":"release","label":"Release"}]},{"id":"note","label":"备注","type":"text","required":false}]}"#
        try JSONSerialization.data(withJSONObject: ["response": form]).write(to: dir.appendingPathComponent("ai-output.json"))
        return (model, dir)
    }

    private func startedCard(_ model: AssistantModel) async throws -> AICardReference {
        model.startPersonal()
        for _ in 0..<150 where !model.recentDeliveries.contains(where: { $0.state == .accepted }) { try await Task.sleep(for: .milliseconds(20)) }
        return try XCTUnwrap(model.recentDeliveries.first(where: { $0.state == .accepted })?.card,
                             model.activities.map(\.message).joined(separator: "\n"))
    }

    private func submitCard(_ card: AICardReference, to dir: URL, action: String = "submit", duplicates: Int = 1, actor: String = "self-open", answers: [String: Any]? = nil) throws {
        let context: [String: Any] = ["assistantProtocol": "dws-assistant-v1", "interactionToken": card.interaction!.token,
            "surfaceId": card.surfaceID, "action": action,
            "answers": answers ?? ["build": ["selected": ["release"]], "note": ["custom": "keep-artifacts"]]]
        let body: [String: Any] = ["a2uiEvent": ["version": "1.0", "action": ["context": context,
            "name": "dws_assistant_" + action, "sourceComponentId": action, "surfaceId": card.surfaceID,
            "timestamp": ISO8601DateFormatter().string(from: Date())]], "bizInfoDTO": ["bizId": card.bizID],
                                  "conversationContextDTO": ["openConversationId": "cid-test"], "operatorDTO": ["openDingTalkId": actor],
                                  "triggerTimestamp": Int64(Date().timeIntervalSince1970 * 1000)]
        let lines = try (0..<duplicates).map { _ in
            String(decoding: try JSONSerialization.data(withJSONObject: ["type": "user_card_action_triggered",
                "event_id": UUID().uuidString, "payload": ["body": body]]), as: UTF8.self)
        }
        let file = dir.appendingPathComponent("card-events.ndjson")
        let previous = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        try (previous + lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    private func count(_ name: String, in dir: URL) -> Int {
        ((try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private func addExecutionProgress(to directory: URL) throws {
        let path = directory.appendingPathComponent("gemini")
        let progress = #"""
        echo '{"type":"dws_agent_progress","version":1,"id":"0000000000000001","kind":"command","status":"running"}' >&2
        /bin/sleep 0.9
        echo '{"type":"dws_agent_progress","version":1,"id":"0000000000000001","kind":"command","status":"completed"}' >&2
        """#
        let script = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "echo generated", with: progress + "\necho generated")
        try script.write(to: path, atomically: false, encoding: .utf8)
    }

    func testEmptyMessagesDoNotReadMetadataAndEmojiStillReply() async throws {
        let (model, dir) = try fixture(slowAI: false)
        addTeardownBlock { _ = await model.stopAll() }
        try writeEvents([("group", "empty", "sender", ""), ("group", "blank", "sender", " \n"),
                         ("group", "emoji", "sender", "😂👍")], to: dir.appendingPathComponent("events.ndjson"))
        model.startPersonal()
        for _ in 0..<150 where model.deliveredCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.personalRunning)
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 1)
        XCTAssertEqual(count("metadata-reads", in: dir), 0)
        XCTAssertEqual(count("generations", in: dir), 1)
        XCTAssertEqual(count("sends", in: dir), 1)
        XCTAssertFalse(model.activities.contains { $0.message.contains("回复已停止") })
    }

    func testDeniedImageReadStopsOnlyThatMessageAndClosesCardWithReason() async throws {
        for format in [ReplyFormat.text, .aiCard] {
            let (model, dir) = try fixture(slowAI: false, format: format)
            addTeardownBlock { _ = await model.stopAll() }
            try Data(#"{"success":false,"code":"PAT_ORG_POLICY_DENIED","data":{"scope":"chat.message:list","reasonCode":"COMMAND_INACTIVE","clientSecret":"private-test-value"}}"#.utf8)
                .write(to: dir.appendingPathComponent("image-details-error.json"))
            try writeEvents([("group", "image", "sender", "[图片消息]")], to: dir.appendingPathComponent("events.ndjson"))
            model.startPersonal()
            for _ in 0..<150 where !model.activities.contains(where: { $0.message.contains("请改用文字描述") }) { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertTrue(model.personalRunning)
            _ = await model.stopAll()
            XCTAssertTrue(model.activities.contains { $0.message.contains("当前 DWS 渠道未开放消息内容读取") })
            XCTAssertFalse(model.activities.contains { $0.message.contains("private-test-value") || $0.message.contains("PAT_ORG_POLICY_DENIED") })
            XCTAssertEqual(count("metadata-reads", in: dir), 1)
            XCTAssertEqual(count("generations", in: dir), 0)
            XCTAssertEqual(count("sends", in: dir), 0)
            if format == .aiCard {
                XCTAssertEqual(count("card-creates", in: dir), 1)
                XCTAssertEqual(count("card-updates", in: dir), 1)
                let body = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
                XCTAssertTrue(body.contains("请改用文字描述"))
                XCTAssertFalse(body.contains("处理未完成，请查看面板日志"))
            }
            let commands = try String(contentsOf: dir.appendingPathComponent("commands"), encoding: .utf8)
            XCTAssertFalse(commands.contains("+messages-resource-download"))
            XCTAssertFalse(commands.contains("pat "))

            // The denied message remains deduplicated; a later text message
            // can still be handled under the same account and permissions.
            try writeEvents([("group", "image", "sender", "[图片消息]"), ("group", "text", "sender", "收到👍")],
                            to: dir.appendingPathComponent("events.ndjson"))
            model.startPersonal()
            for _ in 0..<150 where !model.activities.contains(where: { $0.message.contains("AI 生成") }) { try await Task.sleep(for: .milliseconds(20)) }
            _ = await model.stopAll()
            XCTAssertEqual(count("metadata-reads", in: dir), 1)
            XCTAssertEqual(count("generations", in: dir), 1)
            if format == .text { XCTAssertEqual(model.deliveredCount, 1) }
            else { XCTAssertEqual(count("card-creates", in: dir), 2) }
        }
    }

    func testInitialExecutionTimeoutExplainsConversationLimitInLogAndCard() async throws {
        for format in [ReplyFormat.text, .aiCard] {
            let (model, dir) = try fixture(slowAI: false, format: format)
            addTeardownBlock { _ = await model.stopAll() }
            var config = model.config; config.conversations[0].agent.timeout = 180
            try model.persist(config)
            let path = dir.appendingPathComponent("gemini")
            let script = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: #"{"response":"mock answer"}"#, with: #"{"is_error":true,"reason":"execution_timeout"}"#)
            try script.write(to: path, atomically: false, encoding: .utf8)
            model.startPersonal()
            for _ in 0..<150 where !model.activities.contains(where: { $0.message.contains("此会话设置的 180 秒") }) { try await Task.sleep(for: .milliseconds(20)) }
            _ = await model.stopAll()
            let log = try XCTUnwrap(model.activities.first { $0.message.contains("此会话设置的 180 秒") }?.message)
            XCTAssertTrue(log.contains("等待脚本返回")); XCTAssertTrue(log.contains("单次执行超时"))
            XCTAssertFalse(log.contains("Codex：")); XCTAssertFalse(log.contains("Gemini："))
            XCTAssertEqual(count("generations", in: dir), 1)
            XCTAssertEqual(count("sends", in: dir), 0)
            if format == .aiCard {
                XCTAssertEqual(count("card-creates", in: dir), 1)
                let body = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
                XCTAssertTrue(body.contains("此会话设置的 180 秒"))
                XCTAssertFalse(body.contains("处理未完成，请查看面板日志"))
            }
        }
    }

    func testCardContinuationTimeoutExplainsExecutionLimitInsteadOfFormWait() async throws {
        let (model, dir) = try interactiveFixture()
        var config = model.config; config.conversations[0].agent.timeout = 180
        config.conversations[0].cardInteractionTimeout = 60
        try model.persist(config)
        let card = try await startedCard(model)
        try Data(#"{"is_error":true,"reason":"execution_timeout"}"#.utf8).write(to: dir.appendingPathComponent("ai-output.json"))
        try submitCard(card, to: dir)
        for _ in 0..<150 where !model.activities.contains(where: { $0.message.contains("此会话设置的 180 秒") }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        let log = try XCTUnwrap(model.activities.first { $0.message.contains("此会话设置的 180 秒") }?.message)
        XCTAssertFalse(log.contains("卡片等待超时"))
        let body = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(body.contains("此会话设置的 180 秒"))
        XCTAssertFalse(body.contains("dws_assistant_submit"))
        XCTAssertEqual(count("generations", in: dir), 2)
        XCTAssertEqual(count("card-creates", in: dir), 1)
        XCTAssertEqual(count("sends", in: dir), 0)
    }

    func testExecutionProgressUpdatesSameInitialCardAndKeepsFinalSteps() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        addTeardownBlock { _ = await model.stopAll() }
        try addExecutionProgress(to: dir)
        _ = try await startedCard(model)
        _ = await model.stopAll()
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
        XCTAssertEqual(count("sends", in: dir), 0)
        let final = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(final.contains("已运行 1 条命令")); XCTAssertTrue(final.contains("mock answer"))
        XCTAssertTrue(final.contains("「此消息由DWS助手通过DWS CLI自动回复」")); XCTAssertFalse(final.contains("shimmer"))
    }

    func testExecutionProgressUncertaintyDoesNotSendTerminalOrRecreateCard() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        addTeardownBlock { _ = await model.stopAll() }
        try addExecutionProgress(to: dir)
        try Data().write(to: dir.appendingPathComponent("card-update-failure"))
        model.startPersonal()
        for _ in 0..<150 where !model.recentDeliveries.contains(where: { $0.state == .unknown }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 1)
        XCTAssertEqual(count("sends", in: dir), 0)
    }

    func testFollowupExecutionProgressUpdatesOriginalCard() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try Data().write(to: dir.appendingPathComponent("enforce-finished-stream"))
        try addExecutionProgress(to: dir)
        try JSONSerialization.data(withJSONObject: ["response": "构建已完成"]).write(to: dir.appendingPathComponent("ai-output.json"))
        try submitCard(card, to: dir)
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2)
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 4)
        XCTAssertEqual(model.recentDeliveries.first?.card?.surfaceID, card.surfaceID)
        let final = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(final.contains("已运行 1 条命令")); XCTAssertTrue(final.contains("构建已完成"))
        XCTAssertFalse(final.contains("shimmer")); XCTAssertFalse(final.contains("Countdown"))
    }

    func testInteractiveSubmitDoesNotReopenFinishedTransportStream() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try Data().write(to: dir.appendingPathComponent("enforce-finished-stream"))
        try JSONSerialization.data(withJSONObject: ["response": "确认后的任务已完成"]).write(to: dir.appendingPathComponent("ai-output.json"))
        try submitCard(card, to: dir)
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2, model.activities.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(count("generations", in: dir), 2)
        XCTAssertEqual(count("card-creates", in: dir), 1)
        let flows = try String(contentsOf: dir.appendingPathComponent("card-flow-statuses"), encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(flows, ["FINISH", "FINISH", "FINISH"])
        let update = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(update.contains("确认后的任务已完成"))
        XCTAssertFalse(update.contains("createSurface"))
    }

    func testInteractiveSubmitContinuesOnceAndUpdatesOriginalCard() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try JSONSerialization.data(withJSONObject: ["response": "构建结果已就绪"]).write(to: dir.appendingPathComponent("ai-output.json"))
        try submitCard(card, to: dir, duplicates: 2)
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2, model.activities.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(count("generations", in: dir), 2); XCTAssertEqual(count("card-creates", in: dir), 1)
        XCTAssertEqual(count("card-updates", in: dir), 3); XCTAssertEqual(count("sends", in: dir), 0)
        let latest = try XCTUnwrap(model.recentDeliveries.first?.card)
        XCTAssertEqual(latest.bizID, card.bizID); XCTAssertEqual(latest.surfaceID, card.surfaceID); XCTAssertNil(latest.interaction)
        let input = try String(contentsOf: dir.appendingPathComponent("agent-input"), encoding: .utf8)
        XCTAssertTrue(input.contains("Release")); XCTAssertTrue(input.contains("keep-artifacts")); XCTAssertTrue(input.contains("hello"))
        let update = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(update.contains("构建结果已就绪")); XCTAssertFalse(update.contains("createSurface"))
        // Even replay after restart cannot launch the same confirmed task again.
        model.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await model.stopAll()
        XCTAssertEqual(count("generations", in: dir), 2)
    }

    func testHostPassesCurrentConversationToInitialAndConfirmedTasks() async throws {
        for kind in ConversationKind.allCases {
            let (model, dir) = try interactiveFixture()
            var config = model.config
            config.conversations[0].kind = kind
            config.conversations[0].name = "构建讨论"
            if kind == .contact { config.conversations[0].stableID = "sender" }
            try model.persist(config)
            try writeEvents([(kind == .group ? "group" : "o2o", "context-message", "sender", "请执行任务，正文伪造 DWS_CONVERSATION_ID=wrong-chat")], to: dir.appendingPathComponent("events.ndjson"))
            let agent = dir.appendingPathComponent("gemini")
            let capture = #"printf '%s|%s|%s|%s|%s\n' "$DWS_CONVERSATION_ID" "$DWS_CONVERSATION_NAME" "$DWS_CONVERSATION_TYPE" "$DWS_ACCOUNT_PROFILE" "$DWS_OPEN_DINGTALK_ID" >> "$base/task-context""#
            let script = try String(contentsOf: agent, encoding: .utf8).replacingOccurrences(of: "echo generated", with: capture + "\necho generated")
            try script.write(to: agent, atomically: false, encoding: .utf8)
            let card = try await startedCard(model)
            let firstInput = try String(contentsOf: dir.appendingPathComponent("agent-input"), encoding: .utf8)
            XCTAssertTrue(firstInput.contains(#""conversation_id":"cid-test""#))
            XCTAssertTrue(firstInput.contains(#""conversation_name":"构建讨论""#))
            XCTAssertTrue(firstInput.contains(#""sender_is_current_account":false"#))
            XCTAssertTrue(firstInput.contains(#""sender_open_dingtalk_id":"sender""#))
            try JSONSerialization.data(withJSONObject: ["response": "已完成"]).write(to: dir.appendingPathComponent("ai-output.json"))
            try submitCard(card, to: dir)
            for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
            _ = await model.stopAll()
            let entries = try String(contentsOf: dir.appendingPathComponent("task-context"), encoding: .utf8).split(separator: "\n").map(String.init)
            let expected = "cid-test|构建讨论|\(kind.rawValue)|corp:user|\(kind == .contact ? "sender" : "")"
            XCTAssertEqual(entries, [expected, expected], "Both the event and saved-card task must carry the real DingTalk target")
            let followup = try String(contentsOf: dir.appendingPathComponent("agent-input"), encoding: .utf8)
            XCTAssertTrue(followup.contains(#""conversation_id":"cid-test""#))
            XCTAssertTrue(followup.contains(#""conversation_name":"构建讨论""#))
            XCTAssertTrue(followup.contains(#""sender_is_current_account":true"#))
            XCTAssertTrue(followup.contains(#""sender_open_dingtalk_id":"self-open""#))
            XCTAssertTrue(followup.contains(#""request_source":"card_submission""#))
        }
    }

    func testNativeApprovalsFromCardAndPanelReturnToOriginalBridgeProcess() async throws {
        for useCard in [false, true] {
            let (model, dir) = try fixture(slowAI: false)
            guard FileManager.default.isExecutableFile(atPath: model.nativeBridgePath()) else {
                throw XCTSkip("Build the local bridge with scripts/build-bridge.sh before this integration test")
            }
            defer { model.stopPersonal() }
            let engine = dir.appendingPathComponent("codex")
            let script = #"""
            #!/usr/bin/python3
            import sys, json, os
            base = os.path.dirname(os.path.realpath(__file__))
            thread = "native-fixture"
            def emit(value): print(json.dumps(value), flush=True)
            for line in sys.stdin:
                call = json.loads(line)
                with open(os.path.join(base,"native-protocol"),"a") as out: out.write(line)
                method, rid, p = call.get("method"), call.get("id"), call.get("params",{})
                def result(value): emit({"id":rid,"result":value})
                if method == "initialize": result({})
                elif method == "initialized": pass
                elif method == "config/read": result({"config":{"model":"fixture-model","model_reasoning_effort":"medium"}})
                elif method == "model/list": result({"data":[{"model":"fixture-model","isDefault":True}],"nextCursor":None})
                elif method in ("thread/start","thread/resume"):
                    assert p["sandbox"] == "workspace-write" and p["approvalPolicy"] == "on-request" and p["approvalsReviewer"] == "user"
                    result({"thread":{"id":thread},"sandbox":{"type":"workspaceWrite"},"approvalPolicy":"on-request","approvalsReviewer":"user"})
                elif method == "thread/name/set": result({})
                elif method == "turn/start":
                    result({"turn":{"id":"native-turn"}})
                    emit({"id":900,"method":"item/commandExecution/requestApproval","params":{"threadId":thread,"turnId":"native-turn","itemId":"item","command":"printf fixture","cwd":base}})
                elif rid == 900:
                    assert call["result"]["decision"] == "accept"
                    with open(os.path.join(base,"native-resolved"),"w") as out: out.write("accepted")
                    emit({"method":"turn/completed","params":{"threadId":thread,"turn":{"id":"native-turn","status":"completed","items":[{"type":"agentMessage","text":"native approved"}]}}})
                else: raise RuntimeError("unexpected fixture method")
            """#
            try script.write(to: engine, atomically: false, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.path)
            var config = model.config
            config.executablePaths["codex"] = engine.path
            config.conversations[0].agent.engine = .codex
            config.conversations[0].agent.permission = .requestApproval
            try model.persist(config)
            model.startPersonal()
            for _ in 0..<250 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("card-create-body").path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(model.engineApprovals.pending.count, 1, model.activities.map(\.message).joined(separator: "\n"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("native-resolved").path))
            if useCard {
                let data = try Data(contentsOf: dir.appendingPathComponent("card-create-body"))
                let messages = try JSONDecoder().decode([String].self, from: data)
                var action: [String: Any]?
                for message in messages {
                    let object = try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
                    let components = (object?["updateComponents"] as? [String: Any])?["components"] as? [[String: Any]] ?? []
                    if let submit = components.first(where: { $0["id"] as? String == "submit" }) { action = (submit["action"] as? [String: Any])?["event"] as? [String: Any] }
                }
                var callback = try XCTUnwrap(action)
                var context = try XCTUnwrap(callback["context"] as? [String: Any]); context["answers"] = [:]
                callback["context"] = context; callback["surfaceId"] = context["surfaceId"]; callback["sourceComponentId"] = "submit"
                let body: [String: Any] = ["a2uiEvent":["action":callback], "bizInfoDTO":["bizId":"mock-card"],
                    "operatorDTO":["openDingTalkId":"self-open"], "conversationContextDTO":["openConversationId":"cid-test"],
                    "triggerTimestamp":Date().timeIntervalSince1970 * 1000]
                let event = try JSONSerialization.data(withJSONObject: ["type":"user_card_action_triggered", "event_id":"native-submit", "payload":["body":body]])
                try (String(decoding: event, as: UTF8.self) + "\n").write(to: dir.appendingPathComponent("card-events.ndjson"), atomically: true, encoding: .utf8)
            } else {
                model.engineApprovals.resolve(try XCTUnwrap(model.engineApprovals.pending.first).id, approved: true)
            }
            for _ in 0..<250 where !model.recentDeliveries.contains(where: { $0.state == .accepted }) { try await Task.sleep(for: .milliseconds(20)) }
            _ = await model.stopAll()
            XCTAssertTrue(model.engineApprovals.pending.isEmpty)
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("native-resolved"), encoding: .utf8), "accepted")
            XCTAssertEqual(count("card-creates", in: dir), 1)
            XCTAssertEqual(count("sends", in: dir), 1)
            XCTAssertEqual(model.recentDeliveries.count, 1, "Native approvals must not enqueue another AI task")
            let protocolText = try String(contentsOf: dir.appendingPathComponent("native-protocol"), encoding: .utf8)
            XCTAssertEqual(protocolText.components(separatedBy: #""method":"turn/start""#).count - 1, 1)
            XCTAssertEqual(protocolText.components(separatedBy: #""id":900"#).count - 1, 1)
        }
    }

    func testInteractiveCancelClosesCardWithoutLaunchingAI() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try submitCard(card, to: dir, action: "cancel", duplicates: 2)
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2)
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
        XCTAssertNil(model.recentDeliveries.first?.card?.interaction)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8).contains("已取消"))
    }

    func testInteractiveEmptySelectionDoesNotRunOrConsumeCard() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try submitCard(card, to: dir, answers: ["build": ["selected": [String]()]])
        for _ in 0..<100 where !model.activities.contains(where: { $0.message.contains("卡片选项无效") }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.activities.contains { $0.message.contains("卡片选项无效") })
        XCTAssertEqual(count("generations", in: dir), 1)
        XCTAssertEqual(count("card-updates", in: dir), 1)
        XCTAssertFalse(model.recentDeliveries.first?.card?.interaction?.consumed ?? true)
        try submitCard(card, to: dir, action: "cancel", answers: [:])
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2)
        XCTAssertEqual(count("generations", in: dir), 1)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8).contains("已取消"))
    }

    func testInteractiveExpiryClosesOriginalCardWithoutRunningAI() async throws {
        let (model, dir) = try interactiveFixture()
        var c = model.config.conversations[0]; c.cardInteractionTimeout = 45
        try await model.saveConversation(c)
        let saved = try JSONDecoder().decode(AssistantConfig.self, from: Data(contentsOf: model.dataURL.appendingPathComponent("config.json")))
        XCTAssertEqual(saved.conversations[0].cardInteractionTimeout, 45)
        let card = try await startedCard(model)
        model.closeExpiredCards()
        XCTAssertFalse(model.recentDeliveries.first?.card?.interaction?.consumed ?? true)
        let deadline = try XCTUnwrap(card.interaction?.expiresAt)
        XCTAssertEqual(deadline.timeIntervalSince(try XCTUnwrap(card.interaction?.createdAt)), 45, accuracy: 0.001)
        XCTAssertEqual(model.nextCardExpiryDelay(now: deadline.addingTimeInterval(-0.5)), 0.5, accuracy: 0.001)
        model.closeExpiredCards(now: deadline)
        model.closeExpiredCards(now: deadline)
        for _ in 0..<150 where !model.activities.contains(where: { $0.message.contains("卡片等待超时") }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.activities.contains { $0.message.contains("卡片等待超时") })
        try submitCard(card, to: dir)
        try await Task.sleep(for: .milliseconds(100))
        _ = await model.stopAll()
        XCTAssertEqual(count("generations", in: dir), 1)
        XCTAssertEqual(count("card-creates", in: dir), 1)
        XCTAssertEqual(count("card-updates", in: dir), 2)
        let latest = try XCTUnwrap(model.recentDeliveries.first?.card)
        XCTAssertEqual(latest.bizID, card.bizID); XCTAssertEqual(latest.surfaceID, card.surfaceID)
        XCTAssertNil(latest.interaction)
        let update = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(update.contains("卡片已失效")); XCTAssertFalse(update.contains("dws_assistant_submit"))
    }

    func testInteractiveCardsExpiredWhileOfflineCloseAfterServiceRestarts() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        _ = await model.stopAll()
        model.closeExpiredCards(now: try XCTUnwrap(card.interaction?.expiresAt))
        XCTAssertEqual(count("card-updates", in: dir), 1, "A stopped service must not send expiry updates")
        let store = try JSONStore(directory: dir.appendingPathComponent("restarted-state"))
        try store.save(model.config, to: "config.json")
        var saved = try XCTUnwrap(model.recentDeliveries.first)
        saved.card?.interaction?.expiresAt = Date().addingTimeInterval(-1)
        try store.save([saved.id: saved], to: "delivery-ledger.json")
        let restarted = AssistantModel(directory: store.directory)
        addTeardownBlock { _ = await restarted.stopAll() }
        restarted.profile = model.profile; restarted.accountOK = true
        restarted.startPersonal()
        for _ in 0..<150 where !restarted.activities.contains(where: { $0.message.contains("卡片等待超时") }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await restarted.stopAll()
        XCTAssertTrue(restarted.activities.contains { $0.message.contains("卡片等待超时") })
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
        restarted.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await restarted.stopAll()
        XCTAssertEqual(count("card-updates", in: dir), 2, "Already expired cards must not be updated again")
    }

    func testInteractiveUncertainExpiryUpdateIsNotRetried() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try Data().write(to: dir.appendingPathComponent("card-update-failure"))
        let deadline = try XCTUnwrap(card.interaction?.expiresAt)
        model.closeExpiredCards(now: deadline)
        for _ in 0..<150 where !model.recentDeliveries.contains(where: { $0.state == .unknown }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.recentDeliveries.contains { $0.state == .unknown })
        model.closeExpiredCards(now: deadline.addingTimeInterval(10))
        try submitCard(card, to: dir)
        try await Task.sleep(for: .milliseconds(100))
        _ = await model.stopAll()
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
    }

    func testInteractiveForeignActorIsRejectedWithoutConsumingOwnersCard() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try submitCard(card, to: dir, action: "cancel", actor: "another-person")
        for _ in 0..<100 where !model.activities.contains(where: { $0.message.contains("操作者不是当前登录账号") }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.activities.contains { $0.message.contains("操作者不是当前登录账号") })
        XCTAssertEqual(model.recentDeliveries.count, 1)
        XCTAssertFalse(model.recentDeliveries.first?.card?.interaction?.consumed ?? true)
        try submitCard(card, to: dir, action: "cancel")
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2)
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
    }

    func testInteractiveFollowupFormUsesFreshNonceOnSameCard() async throws {
        let (model, dir) = try interactiveFixture(), original = try await startedCard(model)
        try Data().write(to: dir.appendingPathComponent("enforce-finished-stream"))
        // Return the same form from the stub for a second round of clarification.
        try submitCard(original, to: dir)
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        let second = try XCTUnwrap(model.recentDeliveries.first?.card)
        XCTAssertEqual(second.bizID, original.bizID); XCTAssertEqual(second.surfaceID, original.surfaceID)
        XCTAssertNotEqual(second.interaction?.token, original.interaction?.token)
        try submitCard(original, to: dir) // Stale first-round action must not affect the new form.
        try submitCard(second, to: dir, action: "cancel")
        for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 3)
        XCTAssertEqual(count("generations", in: dir), 2); XCTAssertEqual(count("card-creates", in: dir), 1)
        XCTAssertEqual(count("card-updates", in: dir), 4); XCTAssertNil(model.recentDeliveries.first?.card?.interaction)
    }

    func testInteractiveUncertainProgressUpdateDoesNotExecuteOrRetry() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try Data().write(to: dir.appendingPathComponent("card-update-failure"))
        try submitCard(card, to: dir, duplicates: 2)
        for _ in 0..<150 where !model.recentDeliveries.contains(where: { $0.state == .unknown }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
        model.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await model.stopAll()
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
    }

    func testInteractiveConfigurationChangeRejectsOldCardAndRemovesUnusedChannel() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try writeEvents([], to: dir.appendingPathComponent("events.ndjson"))
        var c = model.config.conversations[0]; c.agent.timeout += 10
        try await model.saveConversation(c)
        try submitCard(card, to: dir)
        for _ in 0..<100 where !model.activities.contains(where: { $0.message.contains("会话配置已改变") }) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.activities.contains { $0.message.contains("会话配置已改变") })
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 1)
        c.replyFormat = .text; try await model.saveConversation(c)
        for _ in 0..<100 where model.listenerStates["card|corp:user"] != "已停止" || model.listenerStates[c.id.uuidString] != "监听中" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.listenerStates["card|corp:user"], "已停止")
        XCTAssertEqual(model.listenerStates[c.id.uuidString], "监听中")
        _ = await model.stopAll()
    }

    func testInteractiveStopDuringFollowupPreventsFinalUpdateAndReplay() async throws {
        let (model, dir) = try interactiveFixture(), card = try await startedCard(model)
        try Data().write(to: dir.appendingPathComponent("slow-followup"))
        try submitCard(card, to: dir)
        for _ in 0..<150 where count("generations", in: dir) < 2 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(count("generations", in: dir), 2)
        _ = await model.stopAll()
        XCTAssertEqual(count("card-updates", in: dir), 2)
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        model.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await model.stopAll()
        XCTAssertEqual(count("generations", in: dir), 2); XCTAssertEqual(count("card-updates", in: dir), 2)
    }

    func testConfirmedTaskCanFinishAfterFormDeadline() async throws {
        let (first, dir) = try interactiveFixture(), card = try await startedCard(first)
        _ = await first.stopAll()
        let store = try JSONStore(directory: dir.appendingPathComponent("restarted-state"))
        try store.save(first.config, to: "config.json")
        var saved = try XCTUnwrap(first.recentDeliveries.first)
        saved.card?.interaction?.expiresAt = Date().addingTimeInterval(2)
        try store.save([saved.id: saved], to: "delivery-ledger.json")
        let engine = dir.appendingPathComponent("gemini")
        let script = try String(contentsOf: engine, encoding: .utf8).replacingOccurrences(of: "/bin/sleep 1", with: "/bin/sleep 2.5")
        try script.write(to: engine, atomically: false, encoding: .utf8)
        try Data().write(to: dir.appendingPathComponent("slow-followup"))
        try JSONSerialization.data(withJSONObject: ["response": "确认后任务完成"]).write(to: dir.appendingPathComponent("ai-output.json"))
        let model = AssistantModel(directory: store.directory)
        model.profile = first.profile; model.accountOK = true
        XCTAssertNil(model.storageFailure)
        addTeardownBlock { _ = await model.stopAll() }
        model.startPersonal()
        for _ in 0..<100 where model.listenerStates["card|corp:user"] != "监听中" { try await Task.sleep(for: .milliseconds(10)) }
        try submitCard(card, to: dir)
        for _ in 0..<300 where model.recentDeliveries.filter({ $0.state == .accepted }).count < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.filter { $0.state == .accepted }.count, 2, model.activities.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(count("generations", in: dir), 2)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8).contains("确认后任务完成"))
    }

    func testRulesSaveReloadAndDisablingClearsPreviousReplyContext() async throws {
        let (model, dir) = try fixture(slowAI: false)
        var conversation = model.config.conversations[0]
        conversation.agent.rules = [AgentRule(name: "回复约定", content: "old-rule-marker")]
        try await model.saveConversation(conversation)
        let saved = try JSONDecoder().decode(AssistantConfig.self, from: Data(contentsOf: dir.appendingPathComponent("state/config.json")))
        XCTAssertEqual(saved.conversations[0].agent.rules, conversation.agent.rules)
        let gemini = dir.appendingPathComponent("gemini")
        let script = try String(contentsOf: gemini, encoding: .utf8)
            .replacingOccurrences(of: "/bin/cat >/dev/null", with: "/bin/cat > \"\(dir.path)/agent-input\"")
        try script.write(to: gemini, atomically: false, encoding: .utf8)
        try writeEvents([("group", "rule-m1", "sender", "old-context-marker")], to: dir.appendingPathComponent("events.ndjson"))
        model.startPersonal()
        for _ in 0..<100 where model.deliveredCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.deliveredCount, 1)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("agent-input"), encoding: .utf8).contains("old-rule-marker"))

        try writeEvents([("group", "rule-m2", "sender", "new-request-marker")], to: dir.appendingPathComponent("events.ndjson"))
        conversation.agent.rules[0].enabled = false
        try await model.saveConversation(conversation)
        for _ in 0..<100 where model.deliveredCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 2, model.activities.map(\.message).joined(separator: "\n"))
        let input = try String(contentsOf: dir.appendingPathComponent("agent-input"), encoding: .utf8)
        XCTAssertTrue(input.contains("new-request-marker"))
        XCTAssertFalse(input.contains("old-rule-marker"))
        XCTAssertFalse(input.contains("old-context-marker"), "Replies generated with disabled rules must not influence the new request")
        XCTAssertFalse(model.config.conversations[0].agent.rules[0].enabled)
        XCTAssertEqual(model.config.conversations[0].agent.rules[0].content, "old-rule-marker")
    }

    func testChangingRulesCancelsAnInFlightReply() async throws {
        let (model, dir) = try fixture(slowAI: true)
        model.startPersonal()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("generations").path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("generations").path))
        try writeEvents([], to: dir.appendingPathComponent("events.ndjson"))
        var conversation = model.config.conversations[0]
        conversation.agent.rules = [AgentRule(name: "新规则", content: "新的回复约定")]
        try await model.saveConversation(conversation)
        _ = await model.stopAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
        XCTAssertEqual(model.recentDeliveries.first?.state, .cancelled)
    }

    func testOwnEchoesNeverReplyAcrossFormatsAndTriggersWithAITagOff() async throws {
        for format in ReplyFormat.allCases {
            for mentioned in [false, true] {
                let (model, dir) = try fixture(slowAI: false, format: format)
                var config = model.config
                config.conversations[0].showAITag = false
                config.conversations[0].trigger = mentioned ? .mentioned : .all
                try model.persist(config)
                let type = mentioned ? "at" : "group"
                try writeEvents([
                    ("group", "self-manual", "self-open", "本人手动发出的消息"),
                    (type, "unknown-sender", "", "发送者缺失"),
                    (type, "m1", "sender", "hello"), (type, "m1", "sender", "duplicate")
                ], to: dir.appendingPathComponent("events.ndjson"))
                try writeEvents([
                    ("group", "reply-new-id", "self-open", "模拟服务端转换后的回复内容"),
                    ("at", "reply-new-at-id", "self-open", format == .aiCard ? "DWS助手回复" : "mock answer"),
                    // Identical text from another person is still a new message.
                    (type, "m2", "sender", "mock answer")
                ], to: dir.appendingPathComponent("echoes.ndjson"))
                // Emit echoes while the first send has not returned its receipt yet.
                let dws = dir.appendingPathComponent("dws")
                var script = try String(contentsOf: dws, encoding: .utf8)
                for marker in ["echo sent >> \"$base/sends\"", "echo create >> \"$base/card-creates\""] {
                    script = script.replacingOccurrences(of: marker, with: marker + "\n/bin/sleep 0.15")
                }
                try script.write(to: dws, atomically: false, encoding: .utf8)
                model.startPersonal()
                for _ in 0..<150 where model.recentDeliveries.filter({ $0.state == .delivered || $0.state == .accepted }).count < 2 {
                    try await Task.sleep(for: .milliseconds(20))
                }
                _ = await model.stopAll()
                let detail = "\(format) / \(mentioned): " + model.activities.map(\.message).joined(separator: "\n")
                XCTAssertEqual(model.receivedCount, 2, detail)
                XCTAssertEqual(model.recentDeliveries.count, 2, detail)
                XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("generations"), encoding: .utf8).split(separator: "\n").count, 2, detail)
                let sends = format == .aiCard ? "card-creates" : "sends"
                XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(sends), encoding: .utf8).split(separator: "\n").count, 2, detail)
                let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
                XCTAssertFalse(reactions.contains("--msg-id self-")); XCTAssertFalse(reactions.contains("--msg-id reply-"))
                XCTAssertFalse(reactions.contains("unknown-sender"))
            }
        }
    }

    func testPrivateMessagesStillReplyAndIgnoreOwnEchoes() async throws {
        let (model, dir) = try fixture(slowAI: false)
        var config = model.config; config.conversations[0].kind = .contact; config.conversations[0].stableID = "sender"
        try model.persist(config)
        try writeEvents([("o2o", "m1", "sender", "hello")], to: dir.appendingPathComponent("events.ndjson"))
        try writeEvents([("o2o", "reply-new-id", "self-open", "mock answer"),
                         ("o2o", "m2", "sender", "follow up")], to: dir.appendingPathComponent("echoes.ndjson"))
        model.startPersonal()
        for _ in 0..<100 where model.deliveredCount < 2 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 2); XCTAssertEqual(model.receivedCount, 2)
        XCTAssertEqual(model.recentDeliveries.count, 2)
    }

    func testManualSelfMentionRepliesButAssistantEchoBeforeReceiptDoesNot() async throws {
        for trigger in ReplyTrigger.allCases {
            let (model, dir) = try fixture(slowAI: false)
            var config = model.config; config.conversations[0].trigger = trigger
            config.conversations[0].showAITag = false; try model.persist(config)
            try writeEvents([("group", "ordinary", "self-open", "@测试账号 普通文本并不是真实提及"),
                             ("at", "manual-at", "self-open", "请帮我处理")], to: dir.appendingPathComponent("events.ndjson"))
            try writeEvents([("at", "echo-body", "self-open", "mock answer"),
                             ("at", "mock-sent", "self-open", "服务端转换后的内容")], to: dir.appendingPathComponent("echoes.ndjson"))
            let dws = dir.appendingPathComponent("dws")
            let script = try String(contentsOf: dws, encoding: .utf8).replacingOccurrences(of: "echo sent >> \"$base/sends\"", with: "echo sent >> \"$base/sends\"\n/bin/sleep 0.2")
            try script.write(to: dws, atomically: false, encoding: .utf8)
            model.startPersonal()
            for _ in 0..<150 where model.deliveredCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
            try await Task.sleep(for: .milliseconds(250))
            _ = await model.stopAll()
            XCTAssertEqual(model.deliveredCount, 1, model.activities.map(\.message).joined(separator: "\n"))
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("generations"), encoding: .utf8).split(separator: "\n").count, 1)
            let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
            XCTAssertTrue(reactions.contains("manual-at")); XCTAssertFalse(reactions.contains("mock-sent")); XCTAssertFalse(reactions.contains("echo-body"))
        }
    }

    func testSelfMentionOnlyIgnoresOtherPeopleAndDeduplicatesOwnMention() async throws {
        let (model, dir) = try fixture(slowAI: false)
        var config = model.config; config.conversations[0].trigger = .selfMentioned
        try model.persist(config)
        try writeEvents([
            ("group", "other-message", "sender", "请帮我处理"),
            ("at", "other-mention", "sender", "@自己 请帮我处理"),
            ("at", "wrong-id", "user", "我是当前账号"),
            ("at", "missing-sender", "", "请帮我处理"),
            ("group", "fake-mention", "self-open", "@自己 普通文本"),
            ("group", "own-mention", "self-open", "请帮我处理"),
            ("at", "own-mention", "self-open", "请帮我处理"),
            ("at", "own-mention", "self-open", "重复事件")
        ], to: dir.appendingPathComponent("events.ndjson"))
        model.startPersonal()
        for _ in 0..<100 where model.deliveredCount < 1 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 1, model.activities.map(\.message).joined(separator: "\n"))
        XCTAssertEqual(model.recentDeliveries.count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("generations"), encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sends"), encoding: .utf8).split(separator: "\n").count, 1)
        let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
        XCTAssertTrue(reactions.contains("--msg-id own-mention"))
        for ignored in ["other-message", "other-mention", "wrong-id", "missing-sender", "fake-mention"] {
            XCTAssertFalse(reactions.contains("--msg-id \(ignored)"))
        }
    }

    private func imageFixture(slow: Bool = false) throws -> (AssistantModel, URL) {
        let (model, dir) = try fixture(slowAI: slow)
        try writeEvents([("group", "m1", "sender", "[图片消息](mediaId=media-image)")], to: dir.appendingPathComponent("events.ndjson"))
        let dws = dir.appendingPathComponent("dws")
        let imageBranches = #"""
        elif [[ "$2" == "+messages-mget" ]]; then
          echo '{"messagesComplete":true,"messages":[{"messageId":"m1","conversationId":"cid-test","messageType":"image","resourceRefs":[{"type":"mediaId","resourceId":"media-image","contentType":"image","download":{"ready":true,"arguments":{"message-id":"m1","open-conversation-id":"cid-test"}}}]}]}'
        elif [[ "$2" == "+messages-resource-download" ]]; then
          echo download >> "$base/downloads"
          [[ -f "$base/download-delay" ]] && /bin/sleep 1
          /bin/cp "$base/image.png" source-0.bin
          echo '{"resourceId":"media-image","localPath":"source-0.bin"}'
        """#
        let script = try String(contentsOf: dws, encoding: .utf8).replacingOccurrences(of: "elif [[ \"$2\" == \"+messages-send\" ]]; then", with: imageBranches + "\nelif [[ \"$2\" == \"+messages-send\" ]]; then")
        try script.write(to: dws, atomically: false, encoding: .utf8)
        let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1ioAAAAASUVORK5CYII=")!
        try png.write(to: dir.appendingPathComponent("image.png"))
        let gemini = dir.appendingPathComponent("gemini")
        var agent = try String(contentsOf: gemini, encoding: .utf8)
        agent = agent.replacingOccurrences(of: "/bin/cat >/dev/null", with: "/bin/cat > \"\(dir.path)/agent-input\"\nprintf '%s\\n' \"$@\" > \"\(dir.path)/agent-args\"")
        try agent.write(to: gemini, atomically: false, encoding: .utf8)
        return (model, dir)
    }

    func testImageDownloadReachesEngineAndCacheIsRemovedAfterReply() async throws {
        let (model, dir) = try imageFixture()
        model.startPersonal()
        for _ in 0..<150 where model.deliveredCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 1, model.activities.map(\.message).joined(separator: "\n"))
        let prompt = try String(contentsOf: dir.appendingPathComponent("agent-input"), encoding: .utf8)
        let args = try String(contentsOf: dir.appendingPathComponent("agent-args"), encoding: .utf8)
        XCTAssertTrue(prompt.contains("image-0.jpg")); XCTAssertTrue(args.contains("@" + dir.path))
        XCTAssertTrue(args.contains("--include-directories")); XCTAssertFalse(args.contains("media-image"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("state/image-cache").path), [])
    }

    func testImageCardUpdatesActualReadingAndAIStagesBeforeFinalAnswer() async throws {
        let (model, dir) = try imageFixture()
        var config = model.config; config.conversations[0].replyFormat = .aiCard; try model.persist(config)
        let dws = dir.appendingPathComponent("dws")
        let script = try String(contentsOf: dws, encoding: .utf8).replacingOccurrences(of: "echo update >> \"$base/card-updates\"", with:
            "/bin/cat \"$base/card-update-body\" >> \"$base/card-update-history\"\necho >> \"$base/card-update-history\"\nprintf '%s\\n' \"$*\" >> \"$base/card-update-args\"\necho update >> \"$base/card-updates\"")
        try script.write(to: dws, atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<150 where model.recentDeliveries.first?.state != .accepted { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .accepted)
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 2)
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("card-create-body"), encoding: .utf8).contains("正在读取图片"))
        let updates = try String(contentsOf: dir.appendingPathComponent("card-update-history"), encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(updates.first?.contains("图片已读取，AI 正在处理") == true)
        XCTAssertTrue(updates.last?.contains("mock answer") == true)
        let args = try String(contentsOf: dir.appendingPathComponent("card-update-args"), encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(args.first?.contains("INPUTTING") == true); XCTAssertTrue(args.last?.contains("FINISH") == true)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("state/image-cache").path), [])
    }

    func testCancelledImageDownloadCleansCacheAndNeverStartsAI() async throws {
        let (model, dir) = try imageFixture()
        try "".write(to: dir.appendingPathComponent("download-delay"), atomically: true, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("downloads").path) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("generations").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("state/image-cache").path), [])
    }

    func testInvalidImageNeverReachesEngineAndCacheIsRemoved() async throws {
        let (model, dir) = try imageFixture()
        try Data("not an image".utf8).write(to: dir.appendingPathComponent("image.png"))
        model.startPersonal()
        for _ in 0..<100 where !model.recentDeliveries.contains(where: { $0.state == .failed }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .failed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("generations").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("state/image-cache").path), [])
    }

    func testMissingSelfIdentityDoesNotStartListenerOrAI() async throws {
        let (model, dir) = try fixture(slowAI: false)
        try #"{"success":true,"result":[{"name":"测试账号","userId":"someone-else","openDingTalkId":"other-open"}]}"#
            .write(to: dir.appendingPathComponent("identity-result.json"), atomically: true, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where model.notice == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.notice?.contains("无法核验") == true)
        XCTAssertFalse(model.personalRunning); XCTAssertFalse(model.stopping)
        for file in ["listeners", "generations", "sends", "reactions"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(file).path), file)
        }
    }

    func testStopDuringIdentityCheckCannotStartLaterAndCanRetry() async throws {
        let (model, dir) = try fixture(slowAI: false)
        let delay = dir.appendingPathComponent("identity-delay")
        try "".write(to: delay, atomically: true, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("identity-lookups").path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.conversationStatus(model.config.conversations[0]), "核验账号中")
        let stopped = await model.stopAll()
        XCTAssertTrue(stopped); XCTAssertFalse(model.hasActiveWork)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("listeners").path))
        try FileManager.default.removeItem(at: delay)
        model.startPersonal()
        for _ in 0..<100 where model.deliveredCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 1)
    }

    func testEditsDuringIdentityCheckUseLatestConversationConfiguration() async throws {
        let (model, dir) = try fixture(slowAI: false)
        try "".write(to: dir.appendingPathComponent("identity-delay"), atomically: true, encoding: .utf8)
        model.startPersonal()
        let old = model.config.conversations[0]
        await model.setListening(old.id, enabled: false)
        var peer = old; peer.id = UUID(); peer.stableID = "cid-peer"; peer.autoReply = false
        try await model.saveConversation(peer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("listeners").path))
        for _ in 0..<100 where model.listenerStates[peer.id.uuidString] != "监听中" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.listenerStates[peer.id.uuidString], "监听中")
        XCTAssertNotEqual(model.listenerStates[old.id.uuidString], "监听中")
        _ = await model.stopAll()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("listeners"), encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("generations").path))
    }
    func testAICardCreatesOnceFinishesAndRecordsAcceptanceSeparately() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        model.startPersonal()
        for _ in 0..<100 where !model.recentDeliveries.contains(where: { $0.state == .accepted }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .accepted)
        XCTAssertEqual(model.recentDeliveries.first?.card?.bizID, "mock-card")
        XCTAssertEqual(model.deliveredCount, 0); XCTAssertEqual(model.uncertainCount, 1)
        model.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await model.stopAll()
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("card-creates"), encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("card-updates"), encoding: .utf8).split(separator: "\n").count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
    }

    func testAICardAppearsBeforeAIAndFinalAnswerReplacesSameCard() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        addTeardownBlock { _ = await model.stopAll() }
        let gate = dir.appendingPathComponent("hold-ai")
        try Data().write(to: gate)
        let gemini = dir.appendingPathComponent("gemini")
        let script = try String(contentsOf: gemini, encoding: .utf8).replacingOccurrences(of: "echo '{\"response\":\"mock answer\"}'",
            with: "while [[ -f \"\(gate.path)\" ]]; do /bin/sleep 0.02; done\necho '{\"response\":\"mock answer\"}'")
        try script.write(to: gemini, atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<150 where count("generations", in: dir) < 1 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(count("generations", in: dir), 1)
        XCTAssertEqual(count("card-creates", in: dir), 1, "The placeholder must already exist while the AI is running")
        XCTAssertEqual(count("card-updates", in: dir), 0)
        let original = try XCTUnwrap(model.recentDeliveries.first?.card)
        let initial = try String(contentsOf: dir.appendingPathComponent("card-create-body"), encoding: .utf8)
        XCTAssertTrue(initial.contains("[AIGenerating]思考中")); XCTAssertTrue(initial.contains("shimmer"))
        XCTAssertTrue(initial.contains("CollapsiblePanel")); XCTAssertTrue(initial.contains("reasoning"))
        XCTAssertFalse(initial.contains("mock answer"))
        try FileManager.default.removeItem(at: gate)
        for _ in 0..<150 where model.recentDeliveries.first?.state != .accepted { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .accepted)
        XCTAssertEqual(model.recentDeliveries.first?.card?.bizID, original.bizID)
        XCTAssertEqual(model.recentDeliveries.first?.card?.surfaceID, original.surfaceID)
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 1)
        let final = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(final.contains("mock answer")); XCTAssertFalse(final.contains("createSurface"))
        XCTAssertFalse(final.contains("AIGenerating")); XCTAssertFalse(final.contains("shimmer"))
    }

    func testAICardUnknownCreationDoesNotStartAIOrCreateAgain() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        let dws = dir.appendingPathComponent("dws")
        let script = try String(contentsOf: dws, encoding: .utf8).replacingOccurrences(of:
            "echo '{\"success\":true,\"result\":{\"bizId\":\"mock-card\"}}'", with: "exit 1")
        try script.write(to: dws, atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<150 where model.recentDeliveries.first?.state != .unknown { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("generations", in: dir), 0)
        model.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await model.stopAll()
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("generations", in: dir), 0)
        XCTAssertEqual(count("card-updates", in: dir), 0); XCTAssertEqual(count("sends", in: dir), 0)
    }

    func testAICardGenerationFailureClosesTheProgressCard() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        try "#!/bin/bash\n/bin/cat >/dev/null\nexit 1\n".write(to: dir.appendingPathComponent("gemini"), atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<150 where model.recentDeliveries.first?.state != .accepted { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .accepted)
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 1)
        XCTAssertEqual(count("sends", in: dir), 0)
        let final = try String(contentsOf: dir.appendingPathComponent("card-update-body"), encoding: .utf8)
        XCTAssertTrue(final.contains("处理未完成")); XCTAssertFalse(final.contains("AIGenerating"))
        XCTAssertTrue(model.activities.contains { $0.message.contains("回复已停止") })
        XCTAssertFalse(model.activities.contains { $0.message.contains("投递未确认") })
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8).contains("打叉"))
    }

    func testSessionDiagnosticsRecordOnlySafeReferenceAndKnownActions() throws {
        let (model, _) = try fixture(slowAI: false)
        let c = model.config.conversations[0]
        model.recordAgentDiagnostics(CommandResult(status: 0, stdout: "{\"session_action\":\"resumed\",\"session_reference\":\"123456abcdef\",\"details\":\"secret-do-not-expose\"}", stderr: "secret-do-not-expose"), conversation: c)
        XCTAssertTrue(model.activities.contains { $0.message.contains("Codex 会话续用 · 123456abcdef") })
        XCTAssertFalse(model.activities.contains { $0.message.contains("secret-do-not-expose") })
        let count = model.activities.count
        model.recordAgentDiagnostics(CommandResult(status: 1, stdout: "{\"session_action\":\"secret-do-not-expose\",\"session_reference\":\"123456abcdef\"}", stderr: ""), conversation: c)
        XCTAssertEqual(model.activities.count, count)
    }

    func testAICardStoppingDuringAILeavesOneCardWithoutResultOrReplay() async throws {
        let (model, dir) = try fixture(slowAI: true, format: .aiCard)
        model.startPersonal()
        for _ in 0..<100 where count("generations", in: dir) < 1 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(count("card-creates", in: dir), 1); XCTAssertEqual(count("card-updates", in: dir), 0)
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        model.startPersonal(); try await Task.sleep(for: .milliseconds(200)); _ = await model.stopAll()
        XCTAssertEqual(count("generations", in: dir), 1); XCTAssertEqual(count("card-creates", in: dir), 1)
    }

    func testAICardUpdateFailureKeepsReferenceWithoutFallbackOrRetry() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        try Data().write(to: dir.appendingPathComponent("card-update-failure"))
        model.startPersonal()
        for _ in 0..<100 where !model.recentDeliveries.contains(where: { $0.state == .unknown }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        XCTAssertEqual(model.recentDeliveries.first?.card?.bizID, "mock-card")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
    }

    func testStoppingDuringCardCreationNeverFinishesOrFallsBack() async throws {
        let (model, dir) = try fixture(slowAI: false, format: .aiCard)
        let dws = dir.appendingPathComponent("dws")
        var script = try String(contentsOf: dws, encoding: .utf8)
        script = script.replacingOccurrences(of: "echo create >> \"$base/card-creates\"", with: "echo create >> \"$base/card-creates\"\n/bin/sleep 1")
        try script.write(to: dws, atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("card-creates").path) { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("card-creates").path))
        _ = await model.stopAll()
        XCTAssertEqual(model.recentDeliveries.first?.state, .unknown)
        XCTAssertNotNil(model.recentDeliveries.first?.card)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("card-updates").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
    }
    func testSingleAccountIgnoresOtherAccountsAndBindsNewConversations() async throws {
        let (model, _) = try fixture(slowAI: false)
        var other = model.config.conversations[0]
        other.id = UUID(); other.profile = "other:user"; other.stableID = "other-group"
        var config = model.config; config.conversations.append(other); try model.persist(config)
        var new = Conversation(); new.stableID = "new-group"
        try await model.saveConversation(new)
        XCTAssertEqual(model.config.conversations.first(where: { $0.id == new.id })?.profile, "corp:user")
        do { try await model.saveConversation(other); XCTFail("Must not rebind another account's conversation") }
        catch { XCTAssertTrue(error.localizedDescription.contains("账号已变化")) }
        XCTAssertEqual(model.conversations.count, 2)
        model.startPersonal()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(model.listenerStates[other.id.uuidString])
        _ = await model.stopAll()
    }

    func testStopDuringGenerationPreventsSend() async throws {
        let (model, dir) = try fixture(slowAI: true)
        model.startPersonal()
        for _ in 0..<50 where model.receivedCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.receivedCount, 1, model.activities.map(\.message).joined(separator: "\n"))
        model.stopPersonal()
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
        XCTAssertFalse(model.personalRunning); XCTAssertFalse(model.stopping)
    }
    func testDuplicateEventsSendOnlyOnceAndSurviveRestart() async throws {
        let (model, dir) = try fixture(slowAI: false)
        model.startPersonal()
        for _ in 0..<100 where model.deliveredCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.deliveredCount, 1, model.activities.map(\.message).joined(separator: "\n"))
        _ = await model.stopAll()
        let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
        let lines = reactions.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("+messages-add-emoji") && lines[0].contains("思考"))
        XCTAssertTrue(lines[1].contains("+messages-remove-emoji") && lines[1].contains("思考"))
        XCTAssertTrue(lines[2].contains("对勾"))
        XCTAssertTrue(model.activities.contains { $0.message.contains("AI 生成") && $0.message.contains("发送") })
        model.startPersonal()
        try await Task.sleep(for: .milliseconds(300))
        _ = await model.stopAll()
        let sends = try String(contentsOf: dir.appendingPathComponent("sends"), encoding: .utf8)
        XCTAssertEqual(sends.split(separator: "\n").count, 1)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("sent-body"), encoding: .utf8), "mock answer")
    }
    func testDisablingOneConversationKeepsOtherListenerAndCancelsItsReply() async throws {
        let (model, dir) = try fixture(slowAI: true)
        let first = model.config.conversations[0]
        var peer = Conversation(); peer.kind = .contact; peer.profile = first.profile; peer.stableID = "peer"; peer.listen = true; peer.agent.workdir = dir.path
        var config = model.config; config.conversations.append(peer); try model.persist(config)
        model.startPersonal()
        for _ in 0..<100 where model.receivedCount == 0 || model.listenerStates[peer.id.uuidString] != "监听中" { try await Task.sleep(for: .milliseconds(20)) }
        await model.setListening(first.id, enabled: false)
        XCTAssertTrue(model.personalRunning)
        XCTAssertEqual(model.listenerStates[peer.id.uuidString], "监听中")
        XCTAssertFalse(model.config.conversations[0].listen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
        await model.setListening(first.id, enabled: true)
        for _ in 0..<50 where model.listenerStates[first.id.uuidString] != "监听中" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.listenerStates[first.id.uuidString], "监听中")
        _ = await model.stopAll()
        let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
        XCTAssertFalse(reactions.contains("对勾")); XCTAssertTrue(reactions.contains("+messages-remove-emoji"))
    }
    func testReactionFailureDoesNotPreventReply() async throws {
        let (model, dir) = try fixture(slowAI: false)
        let dws = dir.appendingPathComponent("dws")
        var script = try String(contentsOf: dws, encoding: .utf8)
        script = script.replacingOccurrences(of: "echo '{\"success\":true}'", with: "echo '{\"error\":{\"message\":\"mock denied\"}}'; exit 1")
        try script.write(to: dws, atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where model.deliveredCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 1)
        XCTAssertTrue(model.activities.contains { $0.message.contains("状态表情失败") })
    }

    func testGenerationFailureUsesFailureReactionAndNeverSends() async throws {
        let (model, dir) = try fixture(slowAI: false)
        try "#!/bin/bash\n/bin/cat >/dev/null\nexit 1\n".write(to: dir.appendingPathComponent("gemini"), atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where !model.activities.contains(where: { $0.message.contains("回复已停止") }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
        let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
        XCTAssertTrue(reactions.contains("打叉")); XCTAssertFalse(reactions.contains("对勾"))
    }
    func testUnknownDeliveryUsesUncertainReaction() async throws {
        let (model, dir) = try fixture(slowAI: false)
        let dws = dir.appendingPathComponent("dws")
        let script = try String(contentsOf: dws, encoding: .utf8).replacingOccurrences(of: "\"deliveryStatus\":\"delivered\"", with: "\"deliveryStatus\":\"pending\"")
        try script.write(to: dws, atomically: false, encoding: .utf8)
        model.startPersonal()
        for _ in 0..<100 where !model.activities.contains(where: { $0.message.contains("投递结果待确认") }) { try await Task.sleep(for: .milliseconds(20)) }
        _ = await model.stopAll()
        XCTAssertEqual(model.deliveredCount, 0); XCTAssertEqual(model.uncertainCount, 1)
        let reactions = try String(contentsOf: dir.appendingPathComponent("reactions"), encoding: .utf8)
        XCTAssertTrue(reactions.contains("迷惑")); XCTAssertFalse(reactions.contains("对勾"))
    }
    func testMentionSubscriptionRemainsUntilLastInterestedGroupStops() async throws {
        let (model, dir) = try fixture(slowAI: false)
        var config = model.config; config.conversations[0].trigger = .mentioned
        var peer = config.conversations[0]; peer.id = UUID(); peer.stableID = "cid-peer"; peer.trigger = .selfMentioned
        config.conversations.append(peer); try model.persist(config)
        model.startPersonal()
        let key = "at|corp:user"
        for _ in 0..<100 where model.listenerStates[key] != "监听中" { try await Task.sleep(for: .milliseconds(20)) }
        await model.setListening(config.conversations[0].id, enabled: false)
        XCTAssertEqual(model.listenerStates[key], "监听中")
        await model.setListening(peer.id, enabled: false)
        for _ in 0..<100 where model.listenerStates[key] != "已停止" { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(model.listenerStates[key], "已停止")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sends").path))
        _ = await model.stopAll()
    }

}
