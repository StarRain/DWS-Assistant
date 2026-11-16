import SwiftUI
import DashboardCore

struct AgentRuleCloner: View {
    private static let panelWidth: CGFloat = 640
    @Environment(\.dismiss) private var dismiss
    let sources: [Conversation]
    let apply: ([AgentRule]) -> Void
    @State private var sourceID: UUID?
    @State private var selected = Set<UUID>()

    private var source: Conversation? { sources.first { $0.id == sourceID } }
    private var rules: [AgentRule] { source?.agent.rules ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("从其他会话克隆").font(.title2.bold())
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            LabeledContent("来源会话") {
                Picker("来源会话", selection: $sourceID) {
                    Text("选择会话").tag(nil as UUID?)
                    ForEach(sources) { conversation in
                        Text("\(conversation.kind == .group ? "群聊" : "私聊") · \(conversation.title)").tag(Optional(conversation.id))
                    }
                }.pickerStyle(.menu).labelsHidden().frame(width: Self.panelWidth / 3, alignment: .trailing)
            }
            if source != nil {
                HStack {
                    Text("选择要克隆的规则").font(.headline)
                    Spacer()
                    Button(selected.count == rules.count ? "取消全选" : "全选") {
                        selected = selected.count == rules.count ? [] : Set(rules.map(\.id))
                    }
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(rules) { rule in
                            Toggle(isOn: Binding(get: { selected.contains(rule.id) }, set: { enabled in
                                if enabled { selected.insert(rule.id) } else { selected.remove(rule.id) }
                            })) {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Text(rule.name).font(.headline)
                                        Spacer()
                                        Text(rule.enabled ? "已开启" : "未开启").font(.caption).foregroundStyle(DashboardTheme.muted)
                                    }
                                    Text(rule.content).font(.body).foregroundStyle(DashboardTheme.secondary)
                                        .lineLimit(3).help(rule.content)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.toggleStyle(.checkbox).padding(14)
                                .background(DashboardTheme.form, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            } else {
                Text("选择一个群聊或私聊，查看其中的规则。")
                    .foregroundStyle(DashboardTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 16) {
                Text("克隆后可独立编辑；完成后需保存会话配置。")
                    .font(.caption).foregroundStyle(DashboardTheme.muted)
                Spacer(minLength: 0)
                Button("克隆 \(selected.count) 条规则") {
                    apply(AgentRules.cloned(rules.filter { selected.contains($0.id) }))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }
        .padding(22).frame(width: Self.panelWidth, height: 520)
        .background(DashboardTheme.background).foregroundStyle(DashboardTheme.text).tint(DashboardTheme.action)
        .dashboardInputFocus()
        .onChange(of: sourceID) { _, _ in selected.removeAll() }
    }
}
