import SwiftUI
import AppKit
import DashboardCore

struct AgentFields: DashboardLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: DashboardModel
    @Binding var value: AgentSettings
    var defaultSessionTitle = "DWS 会话"
    var conversationID: UUID?
    @State private var metadata = EngineMetadata()
    @State private var loading = false
    @State private var metadataError: String?
    @State private var refresh = 0
    @State private var customModel = false
    @State private var metadataKey: String?
    @State private var showingRules = false
    @FocusState private var editingTimeout: Bool

    private var selectedOption: EngineModelOption? { metadata.option(for: value.model) }
    private var efforts: [ReasoningEffort] { selectedOption?.efforts ?? [] }
    private var inheritedEffort: String { metadata.configuredEffort.nonempty ?? selectedOption?.defaultEffort ?? "" }
    private var modelSelection: Binding<String> {
        Binding(get: { customModel ? "__custom__" : value.model }, set: { next in
            customModel = next == "__custom__"
            if !customModel {
                value.model = next
                if let option = metadata.option(for: next), !option.efforts.contains(value.reasoningEffort) { value.reasoningEffort = .inherit }
            }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(l("AI 回复设置")).font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text(diagnostic(metadataError ?? metadata.detail.nonempty ?? l("正在读取引擎模型…")))
                        .lineLimit(1).truncationMode(.tail)
                        .help(diagnostic(metadataError ?? metadata.detail))
                    ZStack {
                        Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                            .buttonStyle(.plain).foregroundStyle(DashboardTheme.accent)
                            .help(l("刷新模型与强度")).disabled(loading).opacity(loading ? 0 : 1)
                        if loading { ProgressView().controlSize(.mini).accessibilityLabel(l("正在刷新模型与强度")) }
                    }.frame(width: 20, height: 20)
                }.font(.caption).foregroundStyle(DashboardTheme.muted)
            }.padding(.horizontal, 10)
            ConfigurationGroup {
                ConfigurationRow(divided: false) {
                    LabeledContent(l("AI 引擎")) {
                        Picker(l("AI 引擎"), selection: $value.engine) { ForEach(Engine.allCases) { Text(tr($0.title)).tag($0) } }.configurationPicker()
                    }
                    .onChange(of: value.engine) { _, _ in value.model = ""; value.reasoningEffort = .inherit; customModel = false; metadata = EngineMetadata() }
                    .task(id: "\(value.engine.rawValue)|\(value.workdir)|\(refresh)") { await loadMetadata() }
                    if value.engine != .custom && model.detectedPaths[value.engine.rawValue] == "未找到" {
                        Text(l("未检测到 \(value.engine.title)，请先安装并完成登录。"))
                            .font(.caption).foregroundStyle(DashboardTheme.muted)
                    }
                }
                if value.engine == .custom {
                    ConfigurationRow {
                        Text(l("启动命令（--agent-cmd）"))
                        TextField(l("例如：python3 /path/to/agent.py"), text: $value.agentCommand)
                            .textFieldStyle(.roundedBorder).font(.body.monospaced())
                            .accessibilityLabel(l("自定义 Agent 启动命令"))
                        Text(l("使用无头、单次执行命令。DWS 将消息追加为最后一个参数，并把标准输出作为回复。"))
                            .font(.caption).foregroundStyle(DashboardTheme.muted)
                        Text(l("模型和权限请在启动命令或 Agent 自身配置中设置；也可使用本地模型。"))
                            .font(.caption).foregroundStyle(DashboardTheme.muted)
                    }
                } else {
                    ConfigurationRow {
                        if metadata.models.isEmpty {
                            LabeledContent(l("模型")) {
                                TextField(l("留空跟随引擎"), text: $value.model).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                            }
                            if !metadata.defaultModel.isEmpty { Text(l("当前默认模型：\(metadata.defaultModel)")).font(.caption).foregroundStyle(DashboardTheme.muted) }
                        } else {
                            LabeledContent(l("模型")) {
                                Picker(l("模型"), selection: modelSelection) {
                                    Text(metadata.defaultModel.isEmpty ? l("跟随引擎") : l("跟随引擎（\(metadata.defaultModel)）")).tag("")
                                    ForEach(metadata.models) { option in Text(option.name).tag(option.id) }
                                    if !value.model.isEmpty && !metadata.models.contains(where: { $0.id == value.model }) { Text(value.model).tag(value.model) }
                                    Divider()
                                    Text(l("填写其他模型…")).tag("__custom__")
                                }.configurationPicker()
                            }
                            if customModel { TextField(l("模型名称"), text: $value.model).textFieldStyle(.roundedBorder) }
                        }
                    }
                }
                if value.engine.supportsReasoning {
                    if !efforts.isEmpty || value.reasoningEffort != .inherit {
                        ConfigurationRow {
                            LabeledContent(l("思考强度")) {
                                Picker(l("思考强度"), selection: $value.reasoningEffort) {
                                    Text(inheritedEffort.isEmpty ? l("跟随引擎") : l("跟随引擎（\(inheritedEffort)）")).tag(ReasoningEffort.inherit)
                                    ForEach(efforts.filter { $0 != .inherit }) { Text($0.rawValue).tag($0) }
                                    if value.reasoningEffort != .inherit && !efforts.contains(value.reasoningEffort) {
                                        Text(l("\(value.reasoningEffort.rawValue)（已保存）")).tag(value.reasoningEffort)
                                    }
                                }.configurationPicker()
                            }
                        }
                    } else if !metadata.configuredEffort.isEmpty {
                        ConfigurationRow { LabeledContent(l("当前默认强度"), value: metadata.configuredEffort) }
                    }
                }
                if value.engine == .codex {
                    ConfigurationRow {
                        LabeledContent(l("Codex 会话名称")) {
                            TextField(defaultSessionTitle, text: $value.sessionTitle)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                                .accessibilityLabel(l("Codex 会话名称"))
                        }
                        Text(l("留空使用默认名称，下次回复时同步到 Codex。"))
                            .font(.caption).foregroundStyle(DashboardTheme.muted)
                    }
                }
                ConfigurationRow {
                    Button { showingRules = true } label: {
                        HStack(spacing: 12) {
                            Text(l("自定义规则")).foregroundStyle(DashboardTheme.text)
                            Spacer()
                            Text(value.rules.isEmpty ? l("添加规则") : l("\(value.rules.filter(\.enabled).count) / \(value.rules.count) 条已开启"))
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(DashboardTheme.accent)
                    Text(l("设置此会话的回复约定或任务步骤。")).font(.caption).foregroundStyle(DashboardTheme.muted)
                }
                ConfigurationRow {
                    HStack {
                        Text(value.engine.supportsAdditionalDirectories ? l("授权目录") : l("工作目录（--agent-workdir）"))
                        Spacer()
                        Button(value.engine.supportsAdditionalDirectories ? l("添加目录") : l("选择目录")) { chooseDirectories() }
                    }
                    ForEach(value.authorizedDirectories, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(DashboardTheme.muted)
                            Text(DashboardPaths.display(path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                .help(DashboardPaths.display(path))
                            Spacer()
                            Button { value.authorizedDirectories.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).help(l("移除此授权目录"))
                        }
                    }
                    Text(value.engine.supportsAdditionalDirectories ? l("可添加允许 AI 读取的目录，支持多个目录。") : l("程序在此目录启动；留空使用独立工作目录。"))
                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                }
                if value.engine != .custom {
                    ConfigurationRow {
                        LabeledContent(l("执行权限")) {
                            Picker(l("执行权限"), selection: $value.permission) { ForEach(ExecutionPermission.allCases) { Text(tr($0.title)).tag($0) } }.configurationPicker()
                        }
                        Text(value.permission == .full ? l("允许引擎按其原生权限执行操作；Codex 可写所选目录。目录列表不构成文件读取沙箱。") : l("Codex 只读，Qoder 关闭工具；其他引擎沿用原生权限。目录列表不构成文件读取沙箱。"))
                            .font(.caption).foregroundStyle(DashboardTheme.muted)
                    }
                }
                ConfigurationRow {
                    HStack(spacing: 6) {
                        Text(l("单次执行超时："))
                        TextField(l("秒数"), value: $value.timeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 56)
                            .multilineTextAlignment(.trailing).focused($editingTimeout)
                            .accessibilityLabel(l("单次执行超时（秒）"))
                            .help(l("10–900 秒，可直接输入"))
                            .onSubmit { normalizeTimeout() }
                            .onChange(of: editingTimeout) { _, editing in if !editing { normalizeTimeout() } }
                        Text(l("秒"))
                        Spacer()
                        Stepper(l("单次执行超时"), value: $value.timeout, in: 10...900, step: 10).labelsHidden()
                    }
                    Text(l("这些设置仅用于当前会话，不修改本机引擎配置。")).font(.caption).foregroundStyle(DashboardTheme.muted)
                }
            }
        }
        .sheet(isPresented: $showingRules) {
            AgentRulesEditor(rules: value.rules, sources: model.conversations.filter { $0.id != conversationID && !$0.agent.rules.isEmpty }) { value.rules = $0 }
                .environment(\.locale, locale)
        }
    }
    private func loadMetadata() async {
        let settings = value, engine = value.engine, workdir = value.workdir
        let key = model.engineMetadataKey(settings)
        // Keep the existing catalog during a refresh. Clearing it briefly
        // replaces the model picker with a text field and removes effort rows.
        if metadataKey != key {
            metadata = model.cachedEngineMetadata(for: settings) ?? EngineMetadata()
            metadataKey = key
        }
        metadataError = nil; loading = true
        do {
            try await Task.sleep(nanoseconds: 250_000_000)
            try Task.checkCancellation()
            let result = try await EngineMetadataReader.read(engine: engine, workdir: workdir, config: model.config,
                                                             cacheDirectory: model.dataURL.appendingPathComponent("engine-metadata"))
            try Task.checkCancellation()
            metadata = result; model.rememberEngineMetadata(result, for: settings); loading = false
        } catch {
            guard !Task.isCancelled, engine == value.engine, workdir == value.workdir else { return }
            if metadata == EngineMetadata() {
                let defaults = EngineDefaults.read(engine: engine, workdir: workdir)
                metadata.defaultModel = defaults.model; metadata.configuredEffort = defaults.effort
                metadataError = error.localizedDescription.localizedCaseInsensitiveContains("not logged in") ? l("请先登录 \(engine.title)，再刷新模型列表") : l("暂未读取到引擎模型列表，可保留默认或填写模型名称")
            } else { metadataError = l("刷新失败，已保留上次结果") }
            loading = false
        }
    }
    private func normalizeTimeout() { value.timeout = min(900, max(10, value.timeout)) }
    private func chooseDirectories() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = value.engine.supportsAdditionalDirectories
        if !value.workdir.isEmpty { panel.directoryURL = URL(fileURLWithPath: value.workdir) }
        panel.prompt = l("添加授权目录")
        guard panel.runModal() == .OK else { return }
        if value.engine.supportsAdditionalDirectories { value.authorizedDirectories += panel.urls.map(\.path) }
        else { value.authorizedDirectories = panel.urls.map(\.path) }
    }
}
