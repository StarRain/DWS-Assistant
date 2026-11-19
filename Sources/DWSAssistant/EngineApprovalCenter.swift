import Foundation
import Combine
import AssistantCore

struct PendingEngineApproval: Identifiable {
    let request: EngineApprovalRequest
    let conversation: Conversation
    var id: String { request.token }
}

@MainActor
final class EngineApprovalCenter: ObservableObject {
    @Published private(set) var pending: [PendingEngineApproval] = []
    private final class Entry {
        let request: EngineApprovalRequest
        let conversation: Conversation
        let checkCurrent: () throws -> Void
        var reference: AICardReference?
        var decision: Bool?
        var continuation: CheckedContinuation<Bool, Never>?
        var timer: Task<Void, Never>?
        init(_ request: EngineApprovalRequest, _ conversation: Conversation, checkCurrent: @escaping () throws -> Void) {
            self.request = request; self.conversation = conversation; self.checkCurrent = checkCurrent
        }
    }
    private var entries: [String: Entry] = [:]

    func wait(_ request: EngineApprovalRequest, conversation: Conversation, checkCurrent: @escaping () throws -> Void,
              prepare: @escaping () async -> AICardReference? = { nil }) async -> Bool {
        guard !Task.isCancelled, request.deadline > Date(), entries[request.token] == nil,
              (try? checkCurrent()) != nil else { return false }
        let entry = Entry(request, conversation, checkCurrent: checkCurrent)
        entries[request.token] = entry
        pending.append(PendingEngineApproval(request: request, conversation: conversation))
        entry.timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, request.deadline.timeIntervalSinceNow))) }
            catch { return }
            self?.resolve(request.token, approved: false)
        }
        defer {
            entry.timer?.cancel(); entries.removeValue(forKey: request.token)
            pending.removeAll { $0.id == request.token }
        }
        return await withTaskCancellationHandler {
            // A local click may arrive while the card is being created. Keep
            // that decision, but never release the RPC before preparation ends.
            entry.reference = await prepare()
            if Task.isCancelled { return false }
            if let decision = entry.decision { return decision && request.deadline > Date() && (try? checkCurrent()) != nil }
            return await withCheckedContinuation { entry.continuation = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(request.token, approved: false) }
        }
    }

    func resolve(_ token: String, approved: Bool) {
        guard let entry = entries[token], entry.decision == nil else { return }
        let valid = entry.request.deadline > Date() && (try? entry.checkCurrent()) != nil
        let decision = approved && valid
        entry.decision = decision
        pending.removeAll { $0.id == token }
        entry.continuation?.resume(returning: decision); entry.continuation = nil
    }

    func bindCard(_ reference: AICardReference, token: String) { entries[token]?.reference = reference }

    func cancelAll() {
        for token in Array(entries.keys) { resolve(token, approved: false) }
    }

    func receive(_ event: CardActionEvent, profile: String, currentSenderID: String) -> Bool {
        guard let (token, entry) = entries.first(where: { $0.value.reference?.bizID == event.bizID && $0.value.reference?.interaction?.token == event.token }) else { return false }
        guard entry.decision == nil, entry.conversation.profile == profile, !currentSenderID.isEmpty,
              event.operatorOpenDingTalkID == currentSenderID,
              (try? entry.checkCurrent()) != nil, let reference = entry.reference,
              (try? event.validate(reference: reference, conversation: entry.conversation, currentSenderID: currentSenderID, nativeApproval: true)) != nil else { return true }
        resolve(token, approved: event.action == "submit")
        return true
    }
}
