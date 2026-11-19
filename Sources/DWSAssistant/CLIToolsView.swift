import SwiftUI
import AppKit
import AssistantCore

struct CLIToolsView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject private var model: AssistantModel
    @ObservedObject var tools: CLIToolsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 16) { heading; Spacer(minLength: 8); controls }
                VStack(alignment: .leading, spacing: 12) { heading; controls }
            }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(CLITool.all) { tool in toolRow(tool) }
                Text(l("安装检测不代表已登录；使用前请在所选引擎中完成登录。"))
                    .font(.caption).foregroundStyle(.secondary)
                Text(l("自定义 Agent 可在会话配置中填写启动命令，无需安装上述引擎。"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).card()
        }
        .task {
            if tools.detectedAt == nil { await model.refreshCLITools() }
        }
    }

    private var heading: some View {
        sectionTitle(l("当前支持的 Agent CLI 工具"), detail: l("检测本机安装与版本，按官方方式安装和更新"))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if tools.activity == .detecting || tools.activity == .checking { ProgressView().controlSize(.small) }
            Button(l("安装检测")) { Task { await model.refreshCLITools() } }
                .help(l("重新检测本机工具和版本号"))
            Button(l("检查更新")) { Task { await model.refreshCLITools(checkUpdates: true) } }
                .help(l("查询官方版本信息，不会自动更新"))
        }.disabled(tools.isBusy || model.preview)
    }

    private func toolRow(_ tool: CLITool) -> some View {
        let installed = tools.installations[tool.id]
        let isRunning = tools.activity == .installing(tool.id) || tools.activity == .updating(tool.id)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CLIToolIcon(tool: tool)
                VStack(alignment: .leading, spacing: 5) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            toolTitle(tool)
                            availableVersionLabel(for: tool)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            toolTitle(tool)
                            availableVersionLabel(for: tool)
                        }
                    }
                    updateLabel(for: tool)
                }
                Spacer(minLength: 8)
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text(installed == nil ? l("安装中…") : l("更新中…")).font(.caption)
                } else if installed != nil {
                    Text(l("已安装")).font(.caption).foregroundStyle(.green)
                } else if tools.detectedAt == nil {
                    Text(l("检测中")).font(.caption).foregroundStyle(.secondary)
                }
                actionButton(for: tool)
            }
            if let error = tools.errors[tool.id] {
                Text(error == "命令已完成，但尚未找到工具；请重新检测或查看官方安装说明。"
                     ? l("命令已完成，但尚未找到工具；请重新检测或查看官方安装说明。")
                     : l("操作未完成，请重试或查看官方说明。"))
                    .font(.caption).foregroundStyle(.red).padding(.leading, 42)
            }
        }
    }

    private func toolTitle(_ tool: CLITool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(tr(tool.title)).font(.headline)
            if let installed = tools.installations[tool.id] {
                Group {
                    if let current = installed.version, let latest = tools.updateVersion(for: tool) {
                        Text("v\(current.text) -> v\(latest.text)").foregroundStyle(.orange)
                    } else {
                        Text(installed.version.map { "v" + $0.text } ?? l("版本未知"))
                    }
                }.font(.caption.monospaced()).foregroundStyle(.secondary).help(installed.path)
            }
        }
    }

    @ViewBuilder
    private func availableVersionLabel(for tool: CLITool) -> some View {
        if tools.installations[tool.id] == nil {
            if let version = tools.availableVersion(for: tool) {
                Text("v\(version.text)").font(.caption.monospaced()).foregroundStyle(.secondary)
            } else {
                Text(tools.isBusy ? l("正在查询版本…") : l("版本暂不可用"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func updateLabel(for tool: CLITool) -> some View {
        if let check = tools.updates[tool.id] {
            switch check {
            case .release(let latest):
                if let current = tools.installations[tool.id]?.version {
                    if latest == current {
                        Text(l("已是最新版本")).foregroundStyle(.secondary).font(.caption)
                    } else if latest < current {
                        Text(l("当前版本高于最新稳定版 v\(latest.text)")).foregroundStyle(.secondary).font(.caption)
                    }
                } else if tools.installations[tool.id] != nil {
                    Text(l("最新稳定版 v\(latest.text)")).foregroundStyle(.secondary).font(.caption)
                }
            case .application:
                Text(l("请在所属桌面应用中检查更新")).font(.caption).foregroundStyle(.secondary)
            case .externalPackageManager:
                Text(l("请通过 Homebrew 检查更新")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func actionButton(for tool: CLITool) -> some View {
        let installed = tools.installations[tool.id] != nil
        let plan = tools.plan(for: tool, overrides: model.config.executablePaths)
        let inUse = model.cliToolInUse(tool)
        let external: Bool = { if case .command = plan { return false }; return true }()
        if !installed || tools.updateVersion(for: tool) != nil {
            Button {
                switch plan {
                case .command(let command): model.manageCLITool(tool, command: command)
                case .documentation(let url): NSWorkspace.shared.open(url)
                case .application(let app): NSWorkspace.shared.open(app)
                }
            } label: {
                Text(installed ? l("更新") : l("安装")).frame(minWidth: 44)
            }
            .disabled(model.preview || tools.detectedAt == nil || tools.isBusy || (!external && inUse))
            .help(inUse && !external ? l("停止使用此工具的助手服务后可更新") : external ? l("打开官方安装说明或所属应用") : l("执行官方安装或更新命令"))
        }
    }
}
