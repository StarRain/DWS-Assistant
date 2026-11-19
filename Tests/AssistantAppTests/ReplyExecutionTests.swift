import XCTest
import AssistantCore
@testable import DWSAssistant

@MainActor
final class ReplyExecutionTests: XCTestCase {
    private var slowCommand: CommandSpec {
        CommandSpec(executable: "/bin/sleep", arguments: ["1"], timeout: 0.05)
    }

    func testDirectEngineLimitAndAdapterWatchdogHaveDifferentCauses() async throws {
        var settings = AgentSettings(); settings.timeout = 180; settings.engine = .gemini
        do {
            _ = try await ReplyExecution.agent(slowCommand, settings: settings)
            XCTFail("Expected the local process timer")
        } catch { XCTAssertEqual(error as? ReplyTimeout, .executionLimit(seconds: 180)) }
        settings.engine = .codex
        do {
            _ = try await ReplyExecution.agent(slowCommand, settings: settings)
            XCTFail("Expected the host watchdog")
        } catch {
            guard case .resultWait = error as? ReplyTimeout else { return XCTFail("Wrong timeout cause: \(error)") }
            XCTAssertFalse(error.localizedDescription.contains("此会话设置"))
        }
    }

    func testDeliveryDeadlineStaysDeliveryFailure() async throws {
        do {
            _ = try await ReplyExecution.command(slowCommand, timeout: ReplyTimeout.messageDelivery)
            XCTFail("Expected a sending timeout")
        } catch {
            guard case .messageDelivery = error as? ReplyTimeout else { return XCTFail("Wrong timeout cause: \(error)") }
            XCTAssertTrue(error.localizedDescription.contains("消息可能已送达"))
        }
    }

    func testCancellingExecutionDoesNotReportTimeout() async throws {
        var settings = AgentSettings(); settings.engine = .gemini
        let task = Task { try await ReplyExecution.agent(CommandSpec(executable: "/bin/sleep", arguments: ["1"], timeout: 10), settings: settings) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertFalse(error is ReplyTimeout) }
    }
}
