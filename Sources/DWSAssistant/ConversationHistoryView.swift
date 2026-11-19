import SwiftUI
import AssistantCore

struct ConversationHistoryView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @Environment(\.dismiss) private var dismiss
    let conversation: Conversation
    let dataDirectory: URL
    @State private var snapshot: CodexHistory.Snapshot?
    @State private var loading = false
    @State private var failure: String?
    @State private var limit = 200

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(systemName: "clock.arrow.circlepath").font(.title2).foregroundStyle(AssistantTheme.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l("会话历史")).font(.title3.weight(.semibold))
                    Text(conversation.title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button(l("刷新")) { Task { await reload() } }.disabled(loading)
                Button(l("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            if let failure {
                ContentUnavailableView(l("历史读取失败"), systemImage: "exclamationmark.triangle", description: Text(failure))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loading && snapshot == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if snapshot?.entries.isEmpty != false {
                ContentUnavailableView(l("暂无会话历史"), systemImage: "bubble.left.and.bubble.right", description: Text(l("该会话完成首次 Codex 回复后，消息和执行记录会显示在这里。")))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if snapshot.hasEarlier && limit < 10_000 {
                            Button(l("加载更早记录")) { limit += 200; Task { await reload() } }.disabled(loading)
                                .frame(maxWidth: .infinity)
                        }
                        ForEach(snapshot.entries) { entry in historyRow(entry) }
                    }.padding(22)
                }
            }
            Divider()
            HStack {
                Label(l("只读查看，不启动 AI"), systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(AssistantPaths.display(dataDirectory.appendingPathComponent("codex").path))
                    .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(.horizontal, 22).padding(.vertical, 14)
        }
        .frame(minWidth: 740, idealWidth: 840, maxWidth: 1000, minHeight: 520, idealHeight: 680)
        .background(AssistantTheme.background)
        .task { await reload() }
    }

    private func historyRow(_ entry: CodexHistory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(entry.kind == .user ? l("用户消息") : entry.kind == .assistant ? l("AI 回复") : l("执行记录"),
                      systemImage: entry.kind == .user ? "person.crop.circle" : entry.kind == .assistant ? "sparkles" : "terminal")
                    .font(.caption.weight(.semibold)).foregroundStyle(entry.kind == .user ? AssistantTheme.accent : AssistantTheme.secondary)
                Spacer()
                Text(displayDate(entry.timestamp)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text(verbatim: entry.kind == .execution ? tr(entry.text) : entry.text)
                .font(.system(size: 13)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if !entry.detail.isEmpty {
                DisclosureGroup(l("查看详情")) {
                    Text(verbatim: entry.detail).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.caption)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.kind == .user ? AssistantTheme.accent.opacity(0.06) : AssistantTheme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func displayDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        return date?.formatted(date: .abbreviated, time: .standard) ?? value
    }

    @MainActor private func reload() async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        let route = conversation.routingKey, directory = dataDirectory, count = limit
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try CodexHistory.load(route: route, dataDirectory: directory, limit: count)
            }.value
            try Task.checkCancellation()
            snapshot = result
        } catch is CancellationError { }
        catch { failure = l("无法读取本地会话记录，请检查数据目录权限或稍后刷新。") }
    }
}
