import SwiftUI
import AppKit
import DashboardCore

struct QuickPanelView: View {
    let prepareToOpenMainWindow: () -> Void
    @EnvironmentObject private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var enabledCount: Int { model.conversations.filter(\.listen).count }
    private var serviceStatus: String { model.stopping ? "关闭中" : model.personalRunning ? "已开启" : "未开启" }
    private var serviceDetail: String {
        if model.stopping { return "正在停止监听和回复…" }
        if model.personalRunning { return "\(model.listeningCount) / \(enabledCount) 个会话正在监听" }
        if model.needsSetup { return "请先在主面板完成安装与登录" }
        if !model.accountOK { return "请先在主面板登录钉钉" }
        if enabledCount == 0 { return "添加会话并开启监听后，即可使用" }
        return "开启后监听已配置的 \(enabledCount) 个会话"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: DashboardBrand.appIcon).resizable().frame(width: 34, height: 34)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("DWS Dashboard").font(.system(size: 14, weight: .semibold))
                    Text(model.accountOK ? model.profile?.name ?? "已登录" : "尚未登录")
                        .font(.system(size: 11)).foregroundStyle(DashboardTheme.secondary).lineLimit(1)
                }
                Spacer()
                Text("v1.0.0").font(.system(size: 10)).foregroundStyle(DashboardTheme.muted)
            }

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("AI 助手服务 · \(serviceStatus)").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    Toggle("AI 助手服务", isOn: Binding(get: { model.personalRunning }, set: {
                        if $0 { model.startPersonal() } else { model.stopPersonal() }
                    }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .disabled(model.preview || model.needsSetup || model.refreshing || model.loggingOut || model.stopping || !model.conversationBusy.isEmpty || model.storageFailure != nil || (!model.personalRunning && (!model.accountOK || enabledCount == 0)))
                }
                HStack(spacing: 6) {
                    Circle().fill(model.personalRunning ? Color.green : DashboardTheme.muted).frame(width: 5, height: 5)
                    Text(serviceDetail).font(.system(size: 10)).foregroundStyle(DashboardTheme.secondary)
                }
                DashboardDivider()
                HStack(spacing: 0) {
                    statistic("监听中", value: model.listeningCount)
                    statistic("处理中", value: model.replyStates.count)
                    statistic("本次已回复", value: model.deliveredCount)
                }
            }.padding(14).card()

            HStack(spacing: 10) {
                conversationShortcut("群聊", page: "groups", kind: .group, icon: .groups)
                conversationShortcut("私聊", page: "contacts", kind: .contact, icon: .contacts)
            }

            Button { showPage("activity") } label: {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("最近动态").font(.system(size: 11, weight: .medium))
                        Spacer()
                        if let activity = model.activities.first {
                            Text(activity.date, format: .dateTime.hour().minute()).font(.system(size: 10)).monospacedDigit()
                        }
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }.foregroundStyle(DashboardTheme.secondary)
                    if let failure = model.storageFailure ?? model.notice {
                        Text(failure).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                    } else if let activity = model.activities.first {
                        Text(activity.message).font(.system(size: 11))
                            .foregroundStyle(activity.level == "错误" ? Color.red : DashboardTheme.text).lineLimit(2)
                    } else {
                        Text("暂无动态，开启助手后可在这里查看状态。")
                            .font(.system(size: 11)).foregroundStyle(DashboardTheme.secondary)
                    }
                }.frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                    .padding(13).card().contentShape(Rectangle())
            }.buttonStyle(.plain)

            HStack(spacing: 8) {
                shortcut("概览", page: "overview", icon: .overview)
                shortcut("日志", page: "activity", icon: .activity)
                shortcut("设置", page: "settings", icon: .settings)
            }
            HStack {
                Button("打开主面板") { showPage("overview") }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(DashboardTheme.accent)
                Spacer()
                Button("关闭助手并退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(DashboardTheme.secondary)
            }.padding(.top, 2)
        }
        .padding(18).frame(width: 360)
        .foregroundStyle(DashboardTheme.text).tint(DashboardTheme.action)
        .background(DashboardTheme.background)
        .preferredColorScheme(model.config.appearance.colorScheme)
    }

    private func statistic(_ title: String, value: Int) -> some View {
        VStack(spacing: 5) {
            Text(value.formatted()).font(.system(size: 22, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(title).font(.system(size: 10)).foregroundStyle(DashboardTheme.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func conversationShortcut(_ title: String, page: String, kind: ConversationKind, icon: DashboardIcon.Kind) -> some View {
        Button { showPage(page) } label: {
            HStack(spacing: 9) {
                DashboardGlyph(kind: icon, size: 20).foregroundStyle(DashboardTheme.accent)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 4)
                Text("\(model.conversations.filter { $0.kind == kind }.count)")
                    .font(.system(size: 12, weight: .medium)).monospacedDigit().foregroundStyle(DashboardTheme.secondary)
            }.padding(13).frame(maxWidth: .infinity).card().contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    private func shortcut(_ title: String, page: String, icon: DashboardIcon.Kind) -> some View {
        Button { showPage(page) } label: {
            HStack(spacing: 6) {
                DashboardGlyph(kind: icon, size: 16)
                Text(title).font(.system(size: 11, weight: .medium))
            }.frame(maxWidth: .infinity, minHeight: 34)
                .foregroundStyle(DashboardTheme.accent)
                .background(DashboardTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
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

struct QuickPanelCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("快捷面板") {
            openWindow(id: "quick-panel")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut("d", modifiers: [.command, .shift])
    }
}
