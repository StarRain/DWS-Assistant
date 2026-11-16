import AppKit

@MainActor
final class DashboardTermination {
    private enum State { case idle, stopping, ready }
    private var state = State.idle

    func request(hasActiveWork: Bool,
                 stop: @escaping @MainActor () async -> Bool,
                 terminate: @escaping @MainActor () -> Void) -> NSApplication.TerminateReply {
        switch state {
        case .ready: return .terminateNow
        case .stopping: return .terminateCancel
        case .idle: break
        }
        guard hasActiveWork else { return .terminateNow }
        state = .stopping
        Task { @MainActor in
            guard await stop() else {
                state = .idle
                return
            }
            state = .ready
            terminate()
        }
        // terminateLater enters AppKit's modal termination loop, which does not
        // service the main-actor tasks needed to stop listeners and replies.
        // Keep the normal event loop running until cleanup requests quit again.
        return .terminateCancel
    }
}
