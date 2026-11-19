import Foundation
import AssistantCore

typealias EngineApprovalHandler = @MainActor (EngineApprovalRequest) async -> Bool
typealias EngineApprovalResponseHandler = @MainActor (EngineApprovalRequest, Bool) async -> Void

struct EngineApprovalCallbacks {
    let decide: EngineApprovalHandler
    let didRespond: EngineApprovalResponseHandler
}

/// Keeps the original helper process and RPC alive while the user decides.
/// No command is reconstructed or replayed after approval.
@MainActor
private final class EngineApprovalConnection {
    let job: ProcessJob
    let handler: EngineApprovalHandler?
    let didRespond: EngineApprovalResponseHandler?
    var finished = false
    var tasks: [String: Task<Void, Never>] = [:]
    var responded = Set<String>()
    init(job: ProcessJob, handler: EngineApprovalHandler?, didRespond: EngineApprovalResponseHandler?) {
        self.job = job; self.handler = handler; self.didRespond = didRespond
    }

    func receive(_ request: EngineApprovalRequest) {
        guard !finished, tasks[request.token] == nil else { return }
        guard tasks.count < 128 else { job.cancel(AssistantError.outputLimit); return }
        tasks[request.token] = Task { @MainActor [self] in
            let approved = await handler?(request) ?? false
            guard !finished, !Task.isCancelled else { return }
            do {
                let accepted = approved && request.deadline > Date()
                try job.sendInput(request.response(approved: accepted))
                responded.insert(request.token)
                // Return the decision before waiting for remote presentation
                // updates, so a slow card API cannot expire a timely approval.
                await didRespond?(request, accepted)
            }
            catch { job.cancel(error) }
        }
    }
    func finish() async {
        finished = true
        let running = Array(tasks.values)
        for (token, task) in tasks where !responded.contains(token) || Task.isCancelled { task.cancel() }
        for task in running { await task.value }
        tasks.removeAll()
    }
}

@MainActor
enum EngineApprovalProcess {
    static func run(_ spec: CommandSpec, job: ProcessJob? = nil, approval: EngineApprovalHandler? = nil, didRespond: EngineApprovalResponseHandler? = nil,
                    progress: @escaping (String) -> Void = { _ in }) async throws -> CommandResult {
        let job = job ?? ProcessJob(spec)
        let connection = EngineApprovalConnection(job: job, handler: spec.keepInputOpen ? approval : nil, didRespond: didRespond)
        let result: Result<CommandResult, Error>
        do {
            result = .success(try await job.value { line, isError in
                guard isError else { return }
                if spec.keepInputOpen, let request = EngineApprovalRequest.parse(line) {
                    Task { @MainActor in connection.receive(request) }
                } else { progress(line) }
            })
        } catch { result = .failure(error) }
        await connection.finish()
        return try result.get()
    }
}
