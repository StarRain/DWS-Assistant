import SwiftUI
import AppKit
import DashboardCore

struct ConversationEditor: View {
    @EnvironmentObject var model: DashboardModel
    @Environment(\.dismiss) var dismiss
    @State var value: Conversation
    @State private var saving = false
    @State private var error: String?
    @FocusState private var editingCardTimeout: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("\(value.kind.title)配置").font(.title2.bold()); Spacer(); Button("取消") { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                ConfigurationSection("会话") {
                    if !value.name.isEmpty {
                        ConfigurationRow(divided: false) {
                            LabeledContent(value.kind == .group ? "群名称" : "联系人名称") {
                                Text(value.name).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }
                    ConfigurationRow(divided: !value.name.isEmpty) {
                        LabeledContent(value.kind == .group ? "群 ID" : "联系人 ID") {
                            Text(value.stableID).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                }
                ConfigurationSection("监听配置") {
                    ConfigurationRow(divided: false) { ConfigurationToggle("监听此会话", isOn: $value.listen) }
                    if value.listen {
                        ConfigurationRow { ConfigurationToggle("自动回复", isOn: $value.autoReply) }
                        if value.autoReply {
                            if value.kind == .group {
                                ConfigurationRow {
                                    LabeledContent("回复触发方式") {
                                        Picker("回复触发方式", selection: $value.trigger) { ForEach(ReplyTrigger.allCases) { Text($0.title).tag($0) } }.configurationPicker()
                                    }
                                    Text("手动 @自己也可触发回复；助手发出的回复会自动过滤。")
                                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                                }
                            }
                            ConfigurationRow {
                                LabeledContent("回复形式") {
                                    Picker("回复形式", selection: $value.replyFormat) { ForEach(ReplyFormat.allCases) { Text($0.title).tag($0) } }.configurationPicker()
                                }
                                if value.replyFormat == .aiCard {
                                    Text("收到消息后先展示「思考中…」，完成后更新同一卡片。支持确认、选项和文字输入；需保持助手服务开启，使用当前钉钉账号操作。")
                                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                                } else if value.replyFormat == .markdown {
                                    Text("支持标题、列表和代码等排版；图片以链接展示。")
                                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                                }
                            }
                            if value.replyFormat == .aiCard {
                                ConfigurationRow {
                                    HStack(spacing: 6) {
                                        Text("卡片等待超时：")
                                        TextField("秒数", value: $value.cardInteractionTimeout, format: .number.grouping(.never))
                                            .textFieldStyle(.roundedBorder).frame(width: 76)
                                            .multilineTextAlignment(.trailing).focused($editingCardTimeout)
                                            .accessibilityLabel("卡片等待超时（秒）")
                                            .help("10–86400 秒，可直接输入")
                                            .onSubmit { normalizeCardTimeout() }
                                            .onChange(of: editingCardTimeout) { _, editing in if !editing { normalizeCardTimeout() } }
                                        Text("秒")
                                        Spacer()
                                        Stepper("卡片等待超时", value: $value.cardInteractionTimeout, in: Conversation.cardInteractionTimeoutRange, step: 10).labelsHidden()
                                    }
                                    Text("等待选择或确认的时限。到期后卡片失效，不会执行任务；保存后用于新卡片。")
                                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                                }
                            } else {
                                ConfigurationRow {
                                    ConfigurationToggle("显示 AI 标签", isOn: $value.showAITag)
                                    if value.showAITag { Text("在个人回复消息上显示 AI 角标。").font(.caption).foregroundStyle(DashboardTheme.muted) }
                                }
                            }
                            ConfigurationRow {
                                ConfigurationToggle("用表情反馈回复状态", isOn: $value.showReplyStatus)
                                if value.showReplyStatus {
                                    Text("在原消息上贴表情：思考 → 处理中，对勾 → 已回复，打叉 → 失败，迷惑 → 投递待确认。")
                                        .font(.caption).foregroundStyle(DashboardTheme.muted)
                                }
                            }
                        }
                    }
                }
                if value.listen && value.autoReply {
                    AgentFields(value: $value.agent, defaultSessionTitle: value.defaultCodexSessionTitle)
                }
                }.padding(20)
            }.toggleStyle(.switch).background(DashboardTheme.background).disabled(saving)
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
                HStack { Text("助手运行时，保存会立即应用此会话的配置。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("保存配置") { saving = true; Task { do { try await model.saveConversation(value); dismiss() } catch { self.error = error.localizedDescription }; saving = false } }.buttonStyle(.borderedProminent).disabled(saving || !model.accountOK) }
            }.padding(20)
        }.frame(width: ConfigurationLayout.panelWidth, height: value.listen && value.autoReply ? 760 : value.listen ? 400 : 360)
            .background(DashboardTheme.background).foregroundStyle(DashboardTheme.text).tint(DashboardTheme.action)
            .dashboardInputFocus()
    }
    private func normalizeCardTimeout() {
        value.cardInteractionTimeout = min(Conversation.cardInteractionTimeoutRange.upperBound, max(Conversation.cardInteractionTimeoutRange.lowerBound, value.cardInteractionTimeout))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: DashboardModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle("外观", detail: "选择浅色、深色，或跟随 macOS 自动切换")
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("主题").font(.headline)
                    Text("立即应用，重新打开后保留选择").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                AppearancePicker()
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            sectionTitle("本机工具", detail: "自动检测已安装的工具，并使用现有登录状态")
            VStack(alignment: .leading, spacing: 18) {
                ForEach(["dws"] + Engine.allCases.map(\.executable), id: \.self) { name in
                    HStack(spacing: 12) {
                        Image(systemName: name == "dws" ? "bubble.left.and.bubble.right" : "sparkles").font(.title3).frame(width: 30)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(name == "dws" ? "钉钉 DWS" : Engine.allCases.first(where: { $0.executable == name })?.title ?? name).font(.headline)
                            Text(name == "dws" ? "登录钉钉、监听消息、发送个人回复" : "可在会话配置中选用的 AI 引擎").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(model.detectedPaths[name] == "未找到" ? "未检测到" : "已检测到").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("每个会话只需选择一个 AI 引擎；检测到程序不代表已完成该引擎的登录。").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            sectionTitle("图片缓存", detail: "只在识别图片时临时使用，处理结束自动清理")
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text("总量上限").font(.headline); Spacer(); Text("64 MB").fontWeight(.medium) }
                Text("单张图片最多 8 MB，每条消息最多 4 张；下载过程中也执行大小限制。").font(.caption).foregroundStyle(.secondary)
                Text("取消或失败时清理本次图片，异常退出留下的文件在下次启动时清理。").font(.caption).foregroundStyle(.secondary)
                Text(DashboardPaths.display(model.dataURL.appendingPathComponent("image-cache").path)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            VStack(alignment: .leading, spacing: 14) {
                Toggle("登录 macOS 时打开面板", isOn: Binding(get: { model.loginAtStartup }, set: { model.setLoginAtStartup($0) })).disabled(model.preview)
                Text("打开应用不会自动启动监听。关闭主窗口会保留菜单栏，退出应用会先停止本应用管理的服务。").font(.caption).foregroundStyle(.secondary)
                HStack { Text("配置与日志"); Spacer(); Button("在 Finder 中查看") { NSWorkspace.shared.open(model.dataURL) } }
                Text(DashboardPaths.display(model.dataURL.path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(24).card()
        }
    }
}
