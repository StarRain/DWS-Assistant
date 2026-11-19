import SwiftUI
import AppKit
import AssistantCore

struct ConversationEditor: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: AssistantModel
    @Environment(\.dismiss) var dismiss
    @State var value: Conversation
    @State private var saving = false
    @State private var error: String?
    @FocusState private var editingCardTimeout: Bool
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text(value.kind == .group ? l("群聊配置") : l("私聊配置")).font(.title2.bold()); Spacer(); Button(l("取消")) { dismiss() }.keyboardShortcut(.cancelAction) }.padding(22)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                ConfigurationSection(l("会话")) {
                    if !value.name.isEmpty {
                        ConfigurationRow(divided: false) {
                            LabeledContent(value.kind == .group ? l("群名称") : l("联系人名称")) {
                                Text(value.name).multilineTextAlignment(.trailing).textSelection(.enabled)
                            }
                        }
                    }
                    ConfigurationRow(divided: !value.name.isEmpty) {
                        LabeledContent(value.kind == .group ? l("群 ID") : l("联系人 ID")) {
                            Text(value.stableID).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                }
                ConfigurationSection(l("监听配置")) {
                    ConfigurationRow(divided: false) { ConfigurationToggle(l("监听此会话"), isOn: $value.listen) }
                    if value.listen {
                        ConfigurationRow { ConfigurationToggle(l("自动回复"), isOn: $value.autoReply) }
                        if value.autoReply {
                            if value.kind == .group {
                                ConfigurationRow {
                                    LabeledContent(l("回复触发方式")) {
                                        Picker(l("回复触发方式"), selection: $value.trigger) { ForEach(ReplyTrigger.allCases) { Text(tr($0.title)).tag($0) } }.configurationPicker()
                                    }
                                    Text(tr(value.trigger.detail))
                                        .font(.caption).foregroundStyle(AssistantTheme.muted)
                                }
                            }
                            ConfigurationRow {
                                LabeledContent(l("回复形式")) {
                                    Picker(l("回复形式"), selection: $value.replyFormat) { ForEach(ReplyFormat.allCases) { Text(tr($0.title)).tag($0) } }.configurationPicker()
                                }
                                if value.replyFormat == .aiCard {
                                    Text(l("收到消息后先展示「思考中…」，完成后更新同一卡片。支持确认、选项和文字输入；需保持助手服务开启，使用当前钉钉账号操作。"))
                                        .font(.caption).foregroundStyle(AssistantTheme.muted)
                                } else if value.replyFormat == .markdown {
                                    Text(l("支持标题、列表和代码等排版；图片以链接展示。"))
                                        .font(.caption).foregroundStyle(AssistantTheme.muted)
                                }
                            }
                            if value.replyFormat == .aiCard {
                                ConfigurationRow {
                                    HStack(spacing: 6) {
                                        Text(l("卡片等待超时："))
                                        TextField(l("秒数"), value: $value.cardInteractionTimeout, format: .number.grouping(.never))
                                            .textFieldStyle(.roundedBorder).frame(width: 76)
                                            .multilineTextAlignment(.trailing).focused($editingCardTimeout)
                                            .accessibilityLabel(l("卡片等待超时（秒）"))
                                            .help(l("10–86400 秒，可直接输入"))
                                            .onSubmit { normalizeCardTimeout() }
                                            .onChange(of: editingCardTimeout) { _, editing in if !editing { normalizeCardTimeout() } }
                                        Text(l("秒"))
                                        Spacer()
                                        Stepper(l("卡片等待超时"), value: $value.cardInteractionTimeout, in: Conversation.cardInteractionTimeoutRange, step: 10).labelsHidden()
                                    }
                                    Text(l("等待选择或确认的时限。到期后卡片失效，不会执行任务；保存后用于新卡片。"))
                                        .font(.caption).foregroundStyle(AssistantTheme.muted)
                                }
                            } else {
                                ConfigurationRow {
                                    ConfigurationToggle(l("显示 AI 标签"), isOn: $value.showAITag)
                                    if value.showAITag { Text(l("在个人回复消息上显示 AI 角标。")).font(.caption).foregroundStyle(AssistantTheme.muted) }
                                }
                            }
                            ConfigurationRow {
                                ConfigurationToggle(l("用表情反馈回复状态"), isOn: $value.showReplyStatus)
                                if value.showReplyStatus {
                                    Text(l("在原消息上贴表情：思考 → 处理中，对勾 → 已回复，打叉 → 失败，迷惑 → 投递待确认。"))
                                        .font(.caption).foregroundStyle(AssistantTheme.muted)
                                }
                            }
                        }
                    }
                }
                if value.listen && value.autoReply {
                    AgentFields(value: $value.agent, defaultSessionTitle: value.defaultCodexSessionTitle, conversationID: value.id)
                }
                }.padding(20)
            }.toggleStyle(.switch).background(AssistantTheme.background).disabled(saving)
            VStack(alignment: .leading, spacing: 10) {
                if let error { Text(diagnostic(error)).foregroundStyle(.red).font(.caption) }
                HStack { Text(l("助手运行时，保存会立即应用此会话的配置。")).font(.caption).foregroundStyle(.secondary); Spacer(); Button(l("保存配置")) { saving = true; Task { do { try await model.saveConversation(value); dismiss() } catch { self.error = error.localizedDescription }; saving = false } }.buttonStyle(.borderedProminent).disabled(saving || !model.accountOK) }
            }.padding(20)
        }.frame(width: ConfigurationLayout.panelWidth, height: value.listen && value.autoReply ? 760 : value.listen ? 400 : 360)
            .background(AssistantTheme.background).foregroundStyle(AssistantTheme.text).tint(AssistantTheme.action)
            .assistantInputFocus()
    }
    private func normalizeCardTimeout() {
        value.cardInteractionTimeout = min(Conversation.cardInteractionTimeoutRange.upperBound, max(Conversation.cardInteractionTimeoutRange.lowerBound, value.cardInteractionTimeout))
    }
}

struct SettingsView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: AssistantModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            sectionTitle(l("外观"), detail: l("选择浅色、深色，或跟随 macOS 自动切换"))
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l("主题")).font(.headline)
                    Text(l("立即应用，重新打开后保留选择")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                AppearancePicker()
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l("界面语言")).font(.headline)
                    Text(l("语言切换立即生效，不影响会话配置和正在运行的助手。")).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                LanguagePicker()
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            CLIToolsView(tools: model.cliTools)
            sectionTitle(l("图片缓存"), detail: l("只在识别图片时临时使用，处理结束自动清理"))
            VStack(alignment: .leading, spacing: 10) {
                HStack { Text(l("总量上限")).font(.headline); Spacer(); Text("64 MB").fontWeight(.medium) }
                Text(l("单张图片最多 8 MB，每条消息最多 4 张；下载过程中也执行大小限制。")).font(.caption).foregroundStyle(.secondary)
                Text(l("取消或失败时清理本次图片，异常退出留下的文件在下次启动时清理。")).font(.caption).foregroundStyle(.secondary)
                Text(AssistantPaths.display(model.dataURL.appendingPathComponent("image-cache").path)).font(.caption.monospaced()).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
            VStack(alignment: .leading, spacing: 14) {
                Toggle(l("登录 macOS 时打开面板"), isOn: Binding(get: { model.loginAtStartup }, set: { model.setLoginAtStartup($0) })).disabled(model.preview)
                Text(l("打开应用不会自动启动监听。关闭主窗口会保留菜单栏，退出应用会先停止本应用管理的服务。")).font(.caption).foregroundStyle(.secondary)
                HStack { Text(l("配置与日志")); Spacer(); Button(l("在 Finder 中查看")) { NSWorkspace.shared.open(model.dataURL) } }
                Text(AssistantPaths.display(model.dataURL.path)).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }.padding(24).card()
        }
    }
}
