import SwiftUI
import AssistantCore

struct EngineApprovalsView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @ObservedObject var center: EngineApprovalCenter

    var body: some View {
        ForEach(center.pending) { item in
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(l("Codex 原生审批"), systemImage: "hand.raised")
                        .font(.headline).foregroundStyle(AssistantTheme.accent)
                    Spacer()
                    Text(item.conversation.title).font(.subheadline)
                }
                Text(tr(item.request.title)).font(.subheadline.weight(.semibold))
                Text(l("命令和文件修改仅批准当前请求；权限申请仅在本轮生效，不修改全局权限。"))
                    .font(.caption).foregroundStyle(AssistantTheme.secondary)
                ScrollView {
                    Text(item.request.displayDetails).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 180).padding(10).background(AssistantTheme.background, in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(l("剩余 \(max(0, Int(item.request.deadline.timeIntervalSince(context.date)))) 秒"))
                            .font(.caption).foregroundStyle(AssistantTheme.secondary)
                    }
                    Spacer()
                    Button(l("拒绝")) { center.resolve(item.id, approved: false) }.buttonStyle(.bordered)
                    Button(l("批准本次操作")) { center.resolve(item.id, approved: true) }.buttonStyle(.borderedProminent)
                }
            }.padding(16).card()
        }
    }
}

struct EngineApprovalShortcut: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @ObservedObject var center: EngineApprovalCenter
    let open: () -> Void
    var body: some View {
        if !center.pending.isEmpty {
            Button(action: open) {
                Label(l("有 \(center.pending.count) 项原生审批待处理"), systemImage: "hand.raised")
                    .font(.system(size: 12, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.bordered).tint(AssistantTheme.accent)
        }
    }
}
