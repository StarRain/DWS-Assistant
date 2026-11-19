import SwiftUI
import AppKit
import AssistantCore

struct QuickPanelView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    let prepareToOpenMainWindow: () -> Void
    @EnvironmentObject private var model: AssistantModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var enabledCount: Int { model.conversations.filter(\.listen).count }
    private var serviceStatus: String { model.stopping ? l("关闭中") : model.personalRunning ? l("已开启") : l("未开启") }
    private var serviceDetail: String {
        if model.stopping { return l("正在停止监听和回复…") }
        if model.personalRunning { return l("\(model.listeningCount) / \(enabledCount) 个会话正在监听") }
        if model.needsSetup { return l("请先在主面板完成安装与登录") }
        if !model.accountOK { return l("请先在主面板登录钉钉") }
        if enabledCount == 0 { return l("添加会话并开启监听后，即可使用") }
        return l("开启后监听已配置的 \(enabledCount) 个会话")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: AssistantBrand.appIcon).resizable().frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l("DWS助手")).font(.system(size: 14, weight: .semibold))
                    Text(model.accountOK ? model.profile?.name ?? l("已登录") : l("尚未登录"))
                        .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary).lineLimit(1)
                }
                Spacer()
                Text("v1.0.0").font(.system(size: 10)).foregroundStyle(AssistantTheme.muted)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text(l("DWS助手服务 · \(serviceStatus)")).font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Toggle(l("DWS助手服务"), isOn: Binding(get: { model.personalRunning }, set: {
                        if $0 { model.startPersonal() } else { model.stopPersonal() }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(model.preview || model.needsSetup || model.refreshing || model.loggingOut || model.stopping || !model.conversationBusy.isEmpty || model.storageFailure != nil || (!model.personalRunning && (!model.accountOK || enabledCount == 0)))
                }
                HStack(spacing: 6) {
                    Circle().fill(model.personalRunning ? Color.green : AssistantTheme.muted).frame(width: 5, height: 5)
                    Text(serviceDetail).font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                }
                AssistantDivider()
                HStack(spacing: 0) {
                    statistic(l("监听中"), value: model.listeningCount)
                    statistic(l("处理中"), value: model.replyStates.count)
                    statistic(l("本次已回复"), value: model.deliveredCount)
                }
            }.padding(14).card()

            HStack(spacing: 10) {
                conversationShortcut(l("群聊"), page: "groups", kind: .group, icon: .groups)
                conversationShortcut(l("私聊"), page: "contacts", kind: .contact, icon: .contacts)
            }

            Button { showPage("activity") } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text(l("最近动态")).font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let activity = model.activities.first {
                            Text(activity.date, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit()
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }.foregroundStyle(AssistantTheme.secondary)
                    if let failure = model.storageFailure ?? model.notice {
                        Text(diagnostic(failure)).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                    } else if let activity = model.activities.first {
                        Text(diagnostic(activity.message)).font(.system(size: 11))
                            .foregroundStyle(activity.level == "错误" ? Color.red : AssistantTheme.text).lineLimit(2)
                    } else {
                        Text(l("暂无动态，开启助手后可在这里查看状态。"))
                            .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .padding(13).card().contentShape(Rectangle())
            }.buttonStyle(.plain)

            HStack(spacing: 8) {
                shortcut(l("概览"), page: "overview", icon: .overview)
                shortcut(l("日志"), page: "activity", icon: .activity)
                shortcut(l("设置"), page: "settings", icon: .settings)
            }
            HStack {
                Button(l("打开主面板")) { showPage("overview") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(AssistantTheme.accent)
                Spacer()
                Button(l("关闭助手并退出")) { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
            }.padding(.top, 2)
        }
        .padding(18).frame(width: 360)
        .foregroundStyle(AssistantTheme.text).tint(AssistantTheme.action)
        .background(AssistantTheme.background)
        .preferredColorScheme(model.config.appearance.colorScheme)
    }

    private func statistic(_ title: String, value: Int) -> some View {
        VStack(spacing: 5) {
            Text(value.formatted()).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func conversationShortcut(_ title: String, page: String, kind: ConversationKind, icon: AssistantIcon.Kind) -> some View {
        Button { showPage(page) } label: {
            HStack(spacing: 9) {
                AssistantGlyph(kind: icon, size: 20).foregroundStyle(AssistantTheme.accent)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text("\(model.conversations.filter { $0.kind == kind }.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(AssistantTheme.secondary)
            }.padding(13).frame(maxWidth: .infinity).card().contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func shortcut(_ title: String, page: String, icon: AssistantIcon.Kind) -> some View {
        Button { showPage(page) } label: {
            HStack(spacing: 6) {
                AssistantGlyph(kind: icon, size: 16)
                Text(title).font(.system(size: 11, weight: .medium))
            }.frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(AssistantTheme.accent)
                .background(AssistantTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func showPage(_ page: String) {
        model.selection = page
        dismiss()
        prepareToOpenMainWindow()
        openWindow(id: "dashboard")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct QuickPanelCommand: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(l("快捷面板")) {
            openWindow(id: "quick-panel")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
