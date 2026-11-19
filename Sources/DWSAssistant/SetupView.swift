import SwiftUI
import AssistantCore

struct SetupView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject private var model: AssistantModel
    @State private var installationRefreshRotation = 0.0

    private let installationURL = URL(string: "https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli#installation")!
    private let authorizationURL = URL(string: "https://github.com/DingTalk-Real-AI/dingtalk-workspace-cli#getting-started")!

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 16) {
                        Image(nsImage: AssistantBrand.appIcon).resizable().frame(width: 62, height: 62).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.config.setupCompleted ? l("连接钉钉，继续使用") : l("欢迎使用 DWS助手")).font(.system(size: 25, weight: .bold))
                            Text(l("检查使用环境，连接你的钉钉账号。")).foregroundStyle(AssistantTheme.secondary)
                        }
                        Spacer(minLength: 0)
                        LanguagePicker()
                    }.padding(.bottom, 8)

                    if let error = model.storageFailure ?? model.notice {
                        Label(diagnostic(error), systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    installation
                    account
                    engines
                }.padding(.horizontal, 24).padding(.top, 46).padding(.bottom, 16)
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.canCompleteSetup ? l("准备就绪") : l("完成 DWS 安装与登录后即可继续")).font(.system(size: 12, weight: .medium))
                    Text(model.config.setupCompleted ? l("登录后恢复已有会话配置，助手服务仍由你手动开启。") : l("进入面板后添加会话，手动开启 DWS助手服务。"))
                        .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
                }
                Spacer(minLength: 0)
                Button { model.completeSetup() } label: {
                    Text(l("进入面板")).frame(minWidth: 74)
                }.buttonStyle(.borderedProminent).controlSize(.large).disabled(!model.canCompleteSetup)
            }.padding(24)
        }
        .frame(maxWidth: 780).frame(maxWidth: .infinity, maxHeight: .infinity)
        .font(.system(size: 13)).foregroundStyle(AssistantTheme.text).tint(AssistantTheme.action)
        .background(AssistantTheme.background)
        .preferredColorScheme(model.config.appearance.colorScheme)
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                icon("terminal")
                VStack(alignment: .leading, spacing: 5) {
                    Text(l("安装 DWS")).font(.headline)
                    Text(l("连接钉钉、监听消息和发送回复所需的官方工具。"))
                        .font(.caption).foregroundStyle(AssistantTheme.secondary)
                }
                Spacer(minLength: 8)
                badge(model.dwsInstalled ? l("已安装") : l("未安装"), ready: model.dwsInstalled)
            }
            HStack {
                if model.dwsInstalled, let path = model.detectedPaths["dws"] {
                    Text(AssistantPaths.display(path)).font(.caption.monospaced())
                        .foregroundStyle(AssistantTheme.secondary).lineLimit(1).truncationMode(.middle).help(path)
                } else {
                    Text(l("安装完成后会自动检测。")).font(.caption).foregroundStyle(AssistantTheme.secondary)
                }
                Spacer()
                Link(l("官方安装说明"), destination: installationURL).font(.caption)
                Button {
                    model.refreshDWSInstallation()
                    withAnimation(.easeOut(duration: 0.35)) { installationRefreshRotation += 360 }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(installationRefreshRotation)).frame(width: 20, height: 20)
                }.help(l("重新检测 DWS 安装")).accessibilityLabel(l("重新检测 DWS 安装"))
                    .disabled(model.preview)
            }
        }.padding(20).card()
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon("person.crop.circle.badge.checkmark")
                VStack(alignment: .leading, spacing: 5) {
                    Text(l("授权与登录")).font(.headline)
                    Text(l("使用当前钉钉账号，通过官方流程完成授权。"))
                        .font(.caption).foregroundStyle(AssistantTheme.secondary)
                }
                Spacer(minLength: 8)
                if model.loggingIn {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(l("等待授权")).font(.caption)
                    }.frame(minWidth: 76)
                } else { badge(accountStatus, ready: model.accountOK) }
            }
            if let profile = model.profile, model.accountOK {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(profile.name).fontWeight(.semibold)
                        Text(profile.organization).font(.caption).foregroundStyle(AssistantTheme.secondary)
                    }
                    Text(diagnostic(model.accountDetail)).font(.caption).foregroundStyle(AssistantTheme.secondary)
                }
            } else if !model.dwsInstalled {
                Text(l("安装 DWS 后继续登录。")).font(.caption).foregroundStyle(AssistantTheme.secondary)
            } else {
                Text(diagnostic(model.accountDetail)).font(.caption).foregroundStyle(AssistantTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                if model.accountCheckState == .signedOut || model.loggingIn {
                    HStack {
                        Button(model.loggingIn ? l("等待官方授权…") : l("去登录")) { model.login() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.loggingIn || model.refreshing || model.preview || model.storageFailure != nil)
                        if model.loggingIn { Button(l("取消授权")) { model.cancelLogin() } }
                        Spacer()
                        Link(l("授权说明"), destination: authorizationURL).font(.caption)
                    }
                } else if model.accountCheckState == .indeterminate {
                    HStack {
                        Text(l("请检查本机 DWS 状态，恢复后会自动更新。")).font(.caption).foregroundStyle(AssistantTheme.secondary)
                        Spacer()
                        Link(l("官方排查说明"), destination: authorizationURL).font(.caption)
                    }
                }
            }
            if !model.loginText.isEmpty && !model.accountOK {
                ScrollView {
                    Text(model.loginText.components(separatedBy: "\n").map(diagnostic).joined(separator: "\n")).font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 112).padding(12).background(AssistantTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(20).card()
    }

    private var engines: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                icon("sparkles")
                VStack(alignment: .leading, spacing: 5) {
                    Text(l("AI 引擎")).font(.headline)
                    Text(l("自动回复需要一个 AI 引擎，可稍后配置。"))
                        .font(.caption).foregroundStyle(AssistantTheme.secondary)
                }
                Spacer(minLength: 8)
                Text(l("\(model.installedEngines.count) 个已安装")).font(.caption).foregroundStyle(AssistantTheme.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 10) {
                ForEach(Engine.installedCLIEngines) { engine in
                    let installed = model.installedEngines.contains(engine)
                    HStack(spacing: 6) {
                        Image(systemName: installed ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(installed ? Color.green : AssistantTheme.muted)
                        Text(engine.title).font(.system(size: 11, weight: .medium))
                    }.frame(maxWidth: .infinity, minHeight: 32)
                        .background(AssistantTheme.subtle, in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel("\(engine.title)，\(installed ? l("已安装") : l("未检测到"))")
                }
            }
            Text(l("安装检测不代表已登录；使用前请在所选引擎中完成登录。"))
                .font(.caption).foregroundStyle(AssistantTheme.secondary)
            Text(l("自定义 Agent 可在会话配置中填写启动命令，无需安装上述引擎。"))
                .font(.caption).foregroundStyle(AssistantTheme.secondary)
        }.padding(20).card()
    }

    private var accountStatus: String {
        switch model.accountCheckState {
        case .authorized: return l("已授权登录")
        case .signedOut: return l("未登录")
        case .indeterminate: return l("待检查")
        case .unchecked where model.refreshing: return l("检测中")
        default: return l("待检测")
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 20, weight: .medium))
            .frame(width: 38, height: 38).foregroundStyle(AssistantTheme.accent)
            .background(AssistantTheme.subtle, in: RoundedRectangle(cornerRadius: 10)).accessibilityHidden(true)
    }

    private func badge(_ title: String, ready: Bool) -> some View {
        Text(title).font(.system(size: 11, weight: .medium))
            .foregroundStyle(ready ? Color.green : AssistantTheme.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(ready ? Color.green.opacity(0.08) : AssistantTheme.subtle, in: Capsule())
    }
}
