import XCTest
import Darwin
@testable import AssistantCore
@testable import DWSAssistant

@MainActor
final class EngineApprovalTests: XCTestCase {
    private func request(seconds: Double = 10) throws -> (EngineApprovalRequest, String) {
        let body: [String: Any] = ["type":"dws_engine_approval", "version":1, "token":String(repeating: "a", count:64),
            "kind":"command", "details":#"{"command":"printf fixture","cwd":"/tmp/project"}"#,
            "expires_at":Date().addingTimeInterval(seconds).timeIntervalSince1970 * 1_000]
        let line = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        return (try XCTUnwrap(EngineApprovalRequest.parse(line)), line)
    }
    private func conversation() -> Conversation {
        var c = Conversation(); c.profile = "corp:user"; c.stableID = "cid-test"; c.name = "Approval fixture"
        c.listen = true; c.autoReply = true; c.replyFormat = .text; c.agent.permission = .requestApproval
        return c
    }
    private func reference(_ request: EngineApprovalRequest, _ c: Conversation) throws -> AICardReference {
        var ref = try request.card(conversation: c, conversationID: c.stableID).pendingReference(conversation: c)
        ref.bizID = "native-card"; return ref
    }
    private func event(_ ref: AICardReference, actor: String? = "self-open", action: String = "submit", target: String = "cid-test") throws -> CardActionEvent {
        let context: [String: Any] = ["assistantProtocol":"dws-assistant-v1", "interactionToken":try XCTUnwrap(ref.interaction).token,
            "surfaceId":ref.surfaceID, "action":action, "answers":[:]]
        let body: [String: Any] = ["actionData":["context":context], "bizInfoDTO":["bizId":ref.bizID],
            "operatorDTO":actor.map { ["openDingTalkId":$0] as [String: Any] } ?? ["uid":123],
            "conversationContextDTO":["openConversationId":target], "triggerTimestamp":Date().timeIntervalSince1970 * 1000]
        return try CardActionEvent(line: String(decoding: JSONSerialization.data(withJSONObject: ["type":"user_card_action_triggered", "event_id":UUID().uuidString, "payload":["body":body]]), as: UTF8.self))
    }
    private func waitPending(_ center: EngineApprovalCenter) async throws {
        for _ in 0..<200 {
            if !center.pending.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("no pending native request")
    }

    func testEitherSurfaceDecidesOnlyOnceAndCardsRequireVerifiedAccount() async throws {
        for localFirst in [false, true] {
            let center = EngineApprovalCenter(), (request, _) = try request(), c = conversation()
            let ref = try reference(request, c)
            let task = Task { await center.wait(request, conversation: c, checkCurrent: {}, prepare: { ref }) }
            try await waitPending(center)
            for actor in ["other", nil] {
                XCTAssertTrue(center.receive(try event(ref, actor: actor), profile: c.profile, currentSenderID: "self-open"))
                XCTAssertEqual(center.pending.count, 1)
            }
            XCTAssertTrue(center.receive(try event(ref), profile: "other:account", currentSenderID: "self-open"))
            XCTAssertTrue(center.receive(try event(ref, target: "other-chat"), profile: c.profile, currentSenderID: "self-open"))
            XCTAssertEqual(center.pending.count, 1)
            let callback = try event(ref)
            if localFirst {
                center.resolve(request.token, approved: false)
                _ = center.receive(callback, profile: c.profile, currentSenderID: "self-open")
            } else {
                XCTAssertTrue(center.receive(callback, profile: c.profile, currentSenderID: "self-open"))
                center.resolve(request.token, approved: false)
                _ = center.receive(callback, profile: c.profile, currentSenderID: "self-open")
            }
            let result = await task.value
            XCTAssertEqual(result, !localFirst)
            XCTAssertTrue(center.pending.isEmpty)
            XCTAssertFalse(center.receive(callback, profile: c.profile, currentSenderID: "self-open"), "Finished requests cannot be replayed")
            XCTAssertFalse(EngineApprovalCenter().receive(callback, profile: c.profile, currentSenderID: "self-open"), "Restart must not restore a live approval")
        }
    }

    func testExpiryCancellationStopAndConfigChangesCannotApprove() async throws {
        for mode in ["expiry", "cancel", "stop", "config"] {
            let center = EngineApprovalCenter(), (request, _) = try request(seconds: mode == "expiry" ? 0.1 : 10), c = conversation()
            var current = true
            let task = Task { await center.wait(request, conversation: c, checkCurrent: { if !current { throw AssistantError.cancelled } }) }
            try await waitPending(center)
            switch mode {
            case "cancel": task.cancel()
            case "stop": center.cancelAll()
            case "config": current = false; center.resolve(request.token, approved: true)
            default: break
            }
            let result = await task.value
            XCTAssertFalse(result, mode); XCTAssertTrue(center.pending.isEmpty, mode)
            center.resolve(request.token, approved: true)
            XCTAssertTrue(center.pending.isEmpty)
        }
    }

    func testDecisionDuringCardCreationIsRetainedButRevalidated() async throws {
        for change in [false, true] {
            let center = EngineApprovalCenter(), (request, _) = try request(), c = conversation()
            var current = true
            var finishPreparation: CheckedContinuation<AICardReference?, Never>?
            let task = Task { await center.wait(request, conversation: c, checkCurrent: { if !current { throw AssistantError.cancelled } }, prepare: {
                await withCheckedContinuation { finishPreparation = $0 }
            }) }
            try await waitPending(center)
            center.resolve(request.token, approved: true)
            current = !change
            try XCTUnwrap(finishPreparation).resume(returning: nil)
            let result = await task.value
            XCTAssertEqual(result, !change)
        }
    }

    private func helper(_ line: String) -> CommandSpec {
        signal(SIGPIPE, SIG_IGN)
        let script = #"""
        import sys, json
        request = json.loads(sys.stdin.readline())
        for _ in range(2): print(json.dumps(request), file=sys.stderr, flush=True)
        response = json.loads(sys.stdin.readline())
        assert response["token"] == request["token"]
        assert response["type"] == "dws_engine_approval_response"
        print(json.dumps({"result":response["decision"]}), flush=True)
        """#
        return CommandSpec(executable: "/usr/bin/python3", arguments: ["-u", "-c", script], stdin: line + "\n", timeout: 3, streaming: true, keepInputOpen: true)
    }

    func testLiveProcessReceivesOneDecisionWithoutRestartAndNoHandlerDeclines() async throws {
        for approved in [false, true] {
            let (_, line) = try request()
            var calls = 0
            let result = try await EngineApprovalProcess.run(helper(line), approval: { _ in
                calls += 1; try? await Task.sleep(for: .milliseconds(20)); return approved
            })
            XCTAssertEqual(calls, 1, "Duplicate native events cannot create a second approval")
            XCTAssertEqual(try Commands.finalAnswer(result, engine: .codex), approved ? "accept" : "decline")
        }
        let (_, line) = try request()
        let result = try await EngineApprovalProcess.run(helper(line))
        XCTAssertEqual(try Commands.finalAnswer(result, engine: .codex), "decline")
    }

    func testStoppingLiveProcessDrainsPendingApproval() async throws {
        let center = EngineApprovalCenter(), (_, line) = try request(), c = conversation()
        let task = Task {
            try await EngineApprovalProcess.run(helper(line), approval: { request in
                await center.wait(request, conversation: c, checkCurrent: {})
            })
        }
        try await waitPending(center)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch {}
        XCTAssertTrue(center.pending.isEmpty, "Process completion must drain approval continuations")
    }

    func testSlowCardPresentationDoesNotDelayNativeDecisionAndDrainsBeforeReturn() async throws {
        let (_, line) = try request(seconds: 2)
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("approval-replied-\(UUID())")
        defer { try? FileManager.default.removeItem(at: marker) }
        var spec = helper(line)
        spec.arguments[2] = spec.arguments[2].replacingOccurrences(of: "assert response[\"token\"]", with: "open(sys.argv[1], 'w').write(response['decision'])\nassert response[\"token\"]")
        spec.arguments.append(marker.path)
        var updated = false
        let result = try await EngineApprovalProcess.run(spec, approval: { _ in true }, didRespond: { _, accepted in
            XCTAssertTrue(accepted)
            for _ in 0..<50 where !FileManager.default.fileExists(atPath: marker.path) { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(try? String(contentsOf: marker, encoding: .utf8), "accept", "The engine must receive the decision before card rendering finishes")
            try? await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(Task.isCancelled, "A completed engine must let the submitted status update drain")
            updated = true
        })
        XCTAssertTrue(updated)
        XCTAssertEqual(try Commands.finalAnswer(result, engine: .codex), "accept")
    }
}
