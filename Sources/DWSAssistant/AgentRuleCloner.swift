import SwiftUI
import AssistantCore

struct AgentRuleCloner: AssistantLocalizedView {
    @Environment(\.locale) var locale
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
                Text(l("从其他会话克隆")).font(.title2.bold())
                Spacer()
                Button(l("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            LabeledContent(l("来源会话")) {
                Picker(l("来源会话"), selection: $sourceID) {
                    Text(l("选择会话")).tag(nil as UUID?)
                    ForEach(sources) { conversation in
                        Text("\(conversation.kind == .group ? l("群聊") : l("私聊")) · \(conversation.title)").tag(Optional(conversation.id))
                    }
                }.pickerStyle(.menu).labelsHidden().frame(width: Self.panelWidth / 3, alignment: .trailing)
            }
            if source != nil {
                HStack {
                    Text(l("选择要克隆的规则")).font(.headline)
                    Spacer()
                    Button(selected.count == rules.count ? l("取消全选") : l("全选")) {
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
                                        Text(rule.enabled ? l("已开启") : l("未开启")).font(.caption).foregroundStyle(AssistantTheme.muted)
                                    }
                                    Text(rule.content).font(.body).foregroundStyle(AssistantTheme.secondary)
                                        .lineLimit(3).help(rule.content)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.toggleStyle(.checkbox).padding(14)
                                .background(AssistantTheme.form, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
            } else {
                Text(l("选择一个群聊或私聊，查看其中的规则。"))
                    .foregroundStyle(AssistantTheme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: 16) {
                Text(l("克隆后可独立编辑；完成后需保存会话配置。"))
                    .font(.caption).foregroundStyle(AssistantTheme.muted)
                Spacer(minLength: 0)
                Button(l("克隆 \(selected.count) 条规则")) {
                    apply(AgentRules.cloned(rules.filter { selected.contains($0.id) }))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty)
            }
        }
        .padding(22).frame(width: Self.panelWidth, height: 520)
        .background(AssistantTheme.background).foregroundStyle(AssistantTheme.text).tint(AssistantTheme.action)
        .assistantInputFocus()
        .onChange(of: sourceID) { _, _ in selected.removeAll() }
    }
}
