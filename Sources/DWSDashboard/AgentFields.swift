import SwiftUI
import AppKit
import DashboardCore

struct AgentFields: View {
    @EnvironmentObject var model: DashboardModel
    @Binding var value: AgentSettings
    var defaultSessionTitle = "DWS 会话"
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
                Text("AI 回复设置").font(.headline)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Text(metadataError ?? metadata.detail.nonempty ?? "正在读取引擎模型…")
                        .lineLimit(1).truncationMode(.tail)
                        .help(metadataError ?? metadata.detail)
                    ZStack {
                        Button { refresh += 1 } label: { Image(systemName: "arrow.clockwise").frame(width: 20, height: 20) }
                            .buttonStyle(.plain).foregroundStyle(DashboardTheme.accent)
                            .help("刷新模型与强度").disabled(loading).opacity(loading ? 0 : 1)
                        if loading { ProgressView().controlSize(.mini).accessibilityLabel("正在刷新模型与强度") }
                    }.frame(width: 20, height: 20)
                }.font(.caption).foregroundStyle(DashboardTheme.muted)
            }.padding(.horizontal, 10)
            ConfigurationGroup {
                ConfigurationRow(divided: false) {
                    LabeledContent("AI 引擎") {
                        Picker("AI 引擎", selection: $value.engine) { ForEach(Engine.allCases) { Text($0.title).tag($0) } }.configurationPicker()
                    }
                    .onChange(of: value.engine) { _, _ in value.model = ""; value.reasoningEffort = .inherit; customModel = false; metadata = EngineMetadata() }
                    .task(id: "\(value.engine.rawValue)|\(value.workdir)|\(refresh)") { await loadMetadata() }
                }
                ConfigurationRow {
                    if metadata.models.isEmpty {
                        LabeledContent("模型") {
                            TextField("留空跟随引擎", text: $value.model).textFieldStyle(.plain).multilineTextAlignment(.trailing)
                        }
                        if !metadata.defaultModel.isEmpty { Text("当前默认模型：\(metadata.defaultModel)").font(.caption).foregroundStyle(DashboardTheme.muted) }
                    } else {
                        LabeledContent("模型") {
                            Picker("模型", selection: modelSelection) {
                                Text(metadata.defaultModel.isEmpty ? "跟随引擎" : "跟随引擎（\(metadata.defaultModel)）").tag("")
                                ForEach(metadata.models) { option in Text(option.name).tag(option.id) }
                                if !value.model.isEmpty && !metadata.models.contains(where: { $0.id == value.model }) { Text(value.model).tag(value.model) }
                                Divider()
                                Text("填写其他模型…").tag("__custom__")
                            }.configurationPicker()
                        }
                        if customModel { TextField("模型名称", text: $value.model).textFieldStyle(.roundedBorder) }
                    }
                }
                if value.engine != .gemini {
                    if !efforts.isEmpty || value.reasoningEffort != .inherit {
                        ConfigurationRow {
                            LabeledContent("思考强度") {
                                Picker("思考强度", selection: $value.reasoningEffort) {
                                    Text(inheritedEffort.isEmpty ? "跟随引擎" : "跟随引擎（\(inheritedEffort)）").tag(ReasoningEffort.inherit)
                                    ForEach(efforts.filter { $0 != .inherit }) { Text($0.rawValue).tag($0) }
                                    if value.reasoningEffort != .inherit && !efforts.contains(value.reasoningEffort) {
                                        Text("\(value.reasoningEffort.rawValue)（已保存）").tag(value.reasoningEffort)
                                    }
                                }.configurationPicker()
                            }
                        }
                    } else if !metadata.configuredEffort.isEmpty {
                        ConfigurationRow { LabeledContent("当前默认强度", value: metadata.configuredEffort) }
                    }
                }
                if value.engine == .codex {
                    ConfigurationRow {
                        LabeledContent("Codex 会话名称") {
                            TextField(defaultSessionTitle, text: $value.sessionTitle)
                                .textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                                .accessibilityLabel("Codex 会话名称")
                        }
                        Text("留空使用默认名称，下次回复时同步到 Codex。")
                            .font(.caption).foregroundStyle(DashboardTheme.muted)
                    }
                }
                ConfigurationRow {
                    Button { showingRules = true } label: {
                        HStack(spacing: 12) {
                            Text("自定义规则").foregroundStyle(DashboardTheme.text)
                            Spacer()
                            Text(value.rules.isEmpty ? "添加规则" : "\(value.rules.filter(\.enabled).count) / \(value.rules.count) 条已开启")
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(DashboardTheme.accent)
                    Text("设置此会话的回复约定或任务步骤。").font(.caption).foregroundStyle(DashboardTheme.muted)
                }
                ConfigurationRow {
                    HStack { Text("授权目录"); Spacer(); Button("添加目录") { chooseDirectories() } }
                    ForEach(value.authorizedDirectories, id: \.self) { path in
                        HStack(spacing: 8) {
                            Image(systemName: "folder").foregroundStyle(DashboardTheme.muted)
                            Text(DashboardPaths.display(path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                                .help(DashboardPaths.display(path))
                            Spacer()
                            Button { value.authorizedDirectories.removeAll { $0 == path } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.plain).help("移除此授权目录")
                        }
                    }
                    Text("可添加允许 AI 读取的目录，支持多个目录。")
                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                }
                ConfigurationRow {
                    LabeledContent("执行权限") {
                        Picker("执行权限", selection: $value.permission) { ForEach(ExecutionPermission.allCases) { Text($0.title).tag($0) } }.configurationPicker()
                    }
                    Text(value.permission == .full ? "允许引擎按其原生权限执行操作；Codex 可写所选目录。目录列表不构成文件读取沙箱。" : "Codex 只读，Qoder 关闭工具；其他引擎沿用原生权限。目录列表不构成文件读取沙箱。")
                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                }
                ConfigurationRow {
                    HStack(spacing: 6) {
                        Text("单次执行超时：")
                        TextField("秒数", value: $value.timeout, format: .number.grouping(.never))
                            .textFieldStyle(.roundedBorder).frame(width: 56)
                            .multilineTextAlignment(.trailing).focused($editingTimeout)
                            .accessibilityLabel("单次执行超时（秒）")
                            .help("10–900 秒，可直接输入")
                            .onSubmit { normalizeTimeout() }
                            .onChange(of: editingTimeout) { _, editing in if !editing { normalizeTimeout() } }
                        Text("秒")
                        Spacer()
                        Stepper("单次执行超时", value: $value.timeout, in: 10...900, step: 10).labelsHidden()
                    }
                    Text("这些设置仅用于当前会话，不修改本机引擎配置。").font(.caption).foregroundStyle(DashboardTheme.muted)
                }
            }
        }
        .sheet(isPresented: $showingRules) {
            AgentRulesEditor(rules: value.rules) { value.rules = $0 }
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
                metadataError = error.localizedDescription.localizedCaseInsensitiveContains("not logged in") ? "请先登录 \(engine.title)，再刷新模型列表" : "暂未读取到引擎模型列表，可保留默认或填写模型名称"
            } else { metadataError = "刷新失败，已保留上次结果" }
            loading = false
        }
    }
    private func normalizeTimeout() { value.timeout = min(900, max(10, value.timeout)) }
    private func chooseDirectories() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if !value.workdir.isEmpty { panel.directoryURL = URL(fileURLWithPath: value.workdir) }
        panel.prompt = "添加授权目录"
        guard panel.runModal() == .OK else { return }
        value.authorizedDirectories += panel.urls.map(\.path)
    }
}
