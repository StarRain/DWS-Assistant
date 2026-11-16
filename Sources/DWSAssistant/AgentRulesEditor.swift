import SwiftUI
import DashboardCore

struct AgentRulesEditor: DashboardLocalizedView {
    @Environment(\.locale) var locale
    @Environment(\.dismiss) private var dismiss
    @State private var rules: [AgentRule]
    @State private var error: String?
    @State private var editingRule: AgentRule?
    @State private var showingClone = false
    private let sources: [Conversation]
    private let apply: ([AgentRule]) -> Void

    init(rules: [AgentRule], sources: [Conversation], apply: @escaping ([AgentRule]) -> Void) {
        _rules = State(initialValue: rules); self.sources = sources; self.apply = apply
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(l("自定义规则")).font(.title2.bold())
                    Spacer()
                    Button(l("从其他会话克隆")) { showingClone = true }
                        .disabled(sources.isEmpty)
                        .help(sources.isEmpty ? l("其他会话还没有可克隆的规则") : l("选择其他会话的规则，复制到当前会话"))
                    Button(l("添加规则"), action: addRule)
                }
                Text(l("为当前会话约定回复方式或任务步骤，AI 会按请求使用已开启的规则。"))
                    .font(.caption).foregroundStyle(DashboardTheme.muted)
            }.padding(22)
            DashboardDivider()
            if rules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.alignleft").font(.system(size: 28)).foregroundStyle(DashboardTheme.accent)
                        .padding(18).background(DashboardTheme.subtle, in: RoundedRectangle(cornerRadius: 16))
                    Text(l("还没有自定义规则")).font(.headline)
                    Text(l("添加回复要求或任务步骤，让 AI 按你的约定处理消息。"))
                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                    Button(l("添加第一条规则"), action: addRule).buttonStyle(.borderedProminent).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 14) {
                            ForEach(rules) { rule in
                                ruleCard(Self.ruleBinding(for: rule, in: $rules)).id(rule.id)
                            }
                        }.padding(20)
                    }
                    .onChange(of: rules.count) { old, new in
                        if new > old, let id = rules.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
            }
            DashboardDivider()
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(diagnostic(error)).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack(alignment: .center, spacing: 20) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(l("共 \(rules.count) 条规则 · \(rules.filter(\.enabled).count) 条已开启"))
                        Text(l("完成后需保存会话配置；规则遵循授权目录和执行权限。"))
                    }.font(.caption).foregroundStyle(DashboardTheme.muted)
                    Spacer(minLength: 0)
                    Button(l("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(l("完成"), action: finish).buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }
        .frame(width: 640, height: 610)
        .background(DashboardTheme.background).foregroundStyle(DashboardTheme.text).tint(DashboardTheme.action)
        .dashboardInputFocus()
        .onChange(of: rules) { _, _ in error = nil }
        .sheet(item: $editingRule) { rule in
            AgentRuleEditor(value: rule, isNew: !rules.contains { $0.id == rule.id }) { saved in
                if let index = rules.firstIndex(where: { $0.id == saved.id }) { rules[index] = saved }
                else { rules.append(saved) }
            }.environment(\.locale, locale)
        }
        .sheet(isPresented: $showingClone) {
            AgentRuleCloner(sources: sources) { rules.append(contentsOf: $0) }.environment(\.locale, locale)
        }
    }

    private func ruleCard(_ rule: Binding<AgentRule>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 16) {
                Text(rule.wrappedValue.name).font(.headline).textSelection(.enabled)
                    .lineLimit(1).help(rule.wrappedValue.name)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 10) {
                    Toggle(l("开启"), isOn: rule.enabled).toggleStyle(.switch).controlSize(.small)
                        .help(l("启用此规则"))
                    Button(l("编辑")) { editingRule = rule.wrappedValue }
                    Button(l("删除"), role: .destructive) { rules.removeAll { $0.id == rule.wrappedValue.id } }
                        .foregroundStyle(.red)
                }.fixedSize()
            }
            Text(rule.wrappedValue.content).font(.body).foregroundStyle(DashboardTheme.secondary)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled).help(rule.wrappedValue.content)
        }.padding(16).background(DashboardTheme.form, in: RoundedRectangle(cornerRadius: 15))
    }

    private func addRule() { editingRule = AgentRule() }

    static func ruleBinding(for rule: AgentRule, in collection: Binding<[AgentRule]>) -> Binding<AgentRule> {
        // A removed row may still deliver a control callback. Keep bindings
        // tied to the rule identity instead of a shifting array index.
        Binding(get: { collection.wrappedValue.first(where: { $0.id == rule.id }) ?? rule },
                set: { next in
                    guard let index = collection.wrappedValue.firstIndex(where: { $0.id == rule.id }) else { return }
                    collection.wrappedValue[index] = next
                })
    }

    private func finish() {
        do {
            try AgentRules.validate(rules)
            apply(rules); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct AgentRuleEditor: DashboardLocalizedView {
    @Environment(\.locale) var locale
    @Environment(\.dismiss) private var dismiss
    @State var value: AgentRule
    let isNew: Bool
    let apply: (AgentRule) -> Void
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(isNew ? l("添加规则") : l("编辑规则")).font(.title2.bold())
                Spacer()
                Button(l("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(l("规则名称")).font(.headline)
                TextField(l("为规则命名，例如：回复风格"), text: $value.name)
                    .textFieldStyle(.roundedBorder).accessibilityLabel(l("规则名称"))
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(l("规则内容")).font(.headline)
                    Spacer()
                    Text("\(value.content.count) / \(AgentRules.maximumContentLength)")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(value.content.count > AgentRules.maximumContentLength ? Color.red : DashboardTheme.muted)
                }
                ZStack(alignment: .topLeading) {
                    if value.content.isEmpty {
                        Text(l("描述这条规则的适用场景、回复要求或任务步骤。\n例如：回答时先给结论，再分点说明；信息不完整时先询问。"))
                            .foregroundStyle(DashboardTheme.muted).padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                    RuleContentEditor(text: $value.content)
                        .padding(.vertical, 4).accessibilityLabel(l("规则内容"))
                }
                .font(.body).frame(minHeight: 180).padding(8)
                .background(DashboardTheme.form, in: RoundedRectangle(cornerRadius: 10))
            }
            HStack(alignment: .center, spacing: 16) {
                if let error { Text(diagnostic(error)).font(.caption).foregroundStyle(.red) }
                Spacer(minLength: 0)
                Button(isNew ? l("添加规则") : l("保存规则"), action: save).buttonStyle(.borderedProminent)
            }
        }
        .padding(22).frame(width: 600, height: 440)
        .background(DashboardTheme.background).foregroundStyle(DashboardTheme.text).tint(DashboardTheme.action)
        .dashboardInputFocus()
        .onChange(of: value) { _, _ in error = nil }
    }

    private func save() {
        do {
            try AgentRules.validate([value])
            apply(value); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
