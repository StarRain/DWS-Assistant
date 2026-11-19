import SwiftUI

struct AccountDetailsView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingLogout = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(l("账号详情")).font(.title2.bold())
                Spacer()
                Button { Task { await model.refreshAccounts() } } label: {
                    Label(l("刷新"), systemImage: "arrow.clockwise")
                }.disabled(model.refreshing || model.loggingOut || model.preview)
                Button(l("关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 8) {
                            Image(systemName: model.accountOK ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                                .foregroundStyle(model.accountOK ? Color.green : AssistantTheme.secondary)
                            Text(tr(model.accountTitle)).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            if model.refreshing || model.loggingOut { ProgressView().controlSize(.small) }
                            else if model.accountOK { Text(l("当前钉钉账号")).font(.caption).foregroundStyle(.secondary) }
                        }
                        if let profile = model.profile {
                            AssistantDivider()
                            HStack(alignment: .top, spacing: 14) {
                                Image(systemName: "person.crop.circle.fill").font(.system(size: 34))
                                    .foregroundStyle(AssistantTheme.accent).frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        Text(profile.name).font(.headline).fixedSize()
                                        Text(profile.organization).font(.system(size: 12)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.tail).help(profile.organization)
                                    }
                                    let ids = profile.id.split(separator: ":", maxSplits: 1).map(String.init)
                                    VStack(alignment: .leading, spacing: 6) {
                                        identifier(l("组织 ID"), value: ids.first ?? "")
                                        identifier(l("用户 ID"), value: ids.dropFirst().first ?? "")
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        } else {
                            Text(diagnostic(model.accountDetail)).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
                    if let notice = model.notice {
                        Text(diagnostic(notice)).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 12) {
                        Text(l("退出时停止助手，保留会话配置。")).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button(model.loggingOut ? l("正在退出…") : l("退出登录"), role: .destructive) { confirmingLogout = true }
                            .disabled(model.loggingOut || model.refreshing || !model.accountOK || model.preview)
                    }
                }.padding(.horizontal, 24).padding(.bottom, 24)
            }
        }.frame(width: 600, height: 360)
            .foregroundStyle(AssistantTheme.text).tint(AssistantTheme.action)
            .background(AssistantTheme.background)
            .confirmationDialog(l("退出当前钉钉账号？"), isPresented: $confirmingLogout, titleVisibility: .visible) {
                Button(l("退出登录"), role: .destructive) { Task { await model.logout() } }
                Button(l("取消"), role: .cancel) {}
            } message: {
                Text(l("将停止 DWS助手服务并退出当前账号。群聊、私聊及其配置会保留，重新登录后可继续使用。"))
            }
    }

    private func identifier(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 10)).frame(width: 46, alignment: .leading)
            Text(value).font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }.foregroundStyle(.secondary)
    }
}
