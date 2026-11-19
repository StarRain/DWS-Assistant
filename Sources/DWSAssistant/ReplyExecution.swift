import Foundation
import AssistantCore

@MainActor
enum ReplyExecution {
    static func agent(_ spec: CommandSpec, settings: AgentSettings, progress: CardProgressUpdates? = nil, approval: EngineApprovalCallbacks? = nil) async throws -> CommandResult {
        do {
            if let progress { return try await progress.run(spec, approval: approval) }
            return try await EngineApprovalProcess.run(spec, approval: approval?.decide, didRespond: approval?.didRespond)
        } catch AssistantError.timedOut {
            // Gemini runs directly under the configured timer. Other adapters
            // report their own configured deadline and have a separate host
            // watchdog with a grace period for returning the final response.
            if settings.engine == .gemini { throw ReplyTimeout.executionLimit(seconds: settings.timeout) }
            throw ReplyTimeout.resultWait(seconds: Int(spec.timeout.rounded()))
        }
    }

    static func command(_ spec: CommandSpec, timeout: (Int) -> ReplyTimeout) async throws -> CommandResult {
        do { return try await ProcessRunner.run(spec) }
        catch AssistantError.timedOut { throw timeout(Int(spec.timeout.rounded())) }
    }
}
