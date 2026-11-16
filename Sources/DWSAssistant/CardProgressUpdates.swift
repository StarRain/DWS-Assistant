import Foundation
import DashboardCore

/// Serializes progress writes and drains the last in-flight request before the
/// caller publishes a terminal card. An uncertain write stops the task once.
@MainActor
final class CardProgressUpdates {
    private let reference: AICardReference
    private let config: DashboardConfig
    private let checkCurrent: @MainActor () throws -> Void
    private let interval: Duration
    private let buffer = AgentProgressBuffer()
    private var ended = false
    private var writing = false
    private var failure: Error?
    private(set) var uncertain = false
    var snapshot: AgentExecutionProgress { buffer.snapshot }

    init(reference: AICardReference, config: DashboardConfig, interval: Duration = .milliseconds(750), checkCurrent: @escaping @MainActor () throws -> Void) {
        self.reference = reference; self.config = config; self.interval = interval; self.checkCurrent = checkCurrent
    }

    func run(_ spec: CommandSpec) async throws -> CommandResult {
        let job = ProcessJob(spec), buffer = buffer
        let updates = Task { @MainActor in
            var revision = 0
            while !ended {
                var sending = false
                do {
                    try await Task.sleep(for: interval)
                    guard !ended else { return }
                    let snapshot = buffer.snapshot
                    guard snapshot.revision > revision else { continue }
                    try checkCurrent()
                    let content = try AICardReply.progressContent(reference, progress: snapshot)
                    var update = try Commands.updateCard(reference, content: content, processing: true, config: config)
                    update.timeout = 8
                    sending = true; writing = true
                    let receipt = try await ProcessRunner.run(update)
                    guard try AICardReply.updateAccepted(receipt, reference: reference) else {
                        throw DashboardError.command("执行进度更新结果待确认，已停止本次处理")
                    }
                    revision = snapshot.revision
                    writing = false
                } catch {
                    if ended && !sending { return }
                    if sending && !Task.isCancelled { uncertain = true }
                    failure = sending ? DashboardError.command("执行进度更新结果待确认，已停止本次处理，不会自动重试") : error
                    job.cancel(failure!)
                    return
                }
            }
        }
        let result: Result<CommandResult, Error>
        do { result = .success(try await job.value { line, isError in if isError { buffer.receive(line: line) } }) }
        catch { result = .failure(error) }
        ended = true
        if Task.isCancelled || !writing { updates.cancel() }
        await updates.value
        if let failure { throw failure }
        return try result.get()
    }
}
