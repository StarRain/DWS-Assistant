import SwiftUI
import AppKit
import AssistantCore

private let accent = AssistantTheme.accent
private let ink = AssistantTheme.text
private let surface = AssistantTheme.background

struct AssistantView: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: AssistantModel
    @State private var query = ""
    @State private var editing: Conversation?
    @State private var history: Conversation?
    @State private var discovery: ConversationKind?
    @State private var removing: Conversation?
    @State private var showingAccount = false
    private let navigation: [(String, String, AssistantIcon.Kind)] = [("overview", "概览", .overview), ("groups", "群聊", .groups), ("contacts", "私聊", .contacts), ("activity", "日志", .activity), ("settings", "设置", .settings)]
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let failure = model.storageFailure { banner(diagnostic(failure), symbol: "exclamationmark.triangle", color: .red) }
                        if let notice = model.notice {
                            HStack(spacing: 12) {
                                Label(diagnostic(notice), systemImage: "exclamationmark.circle")
                                Spacer(minLength: 0)
                                Button { model.notice = nil } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.plain).help(l("关闭提示"))
                            }.font(.system(size: 12)).foregroundStyle(.red).padding(14)
                                .background(Color.red.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        }
                        switch model.selection {
                        case "groups": conversations(.group)
                        case "contacts": conversations(.contact)
                        case "activity": activity
                        case "settings": SettingsView()
                        default: overview
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 24).padding(.vertical, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(surface)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .ignoresSafeArea(.container, edges: .top)
        .font(.system(size: 13)).foregroundStyle(ink).tint(AssistantTheme.action)
        .preferredColorScheme(model.config.appearance.colorScheme)
        .assistantInputFocus()
        .sheet(item: $editing) { ConversationEditor(value: $0).environmentObject(model).environment(\.locale, model.config.language.locale) }
        .sheet(item: $history) { ConversationHistoryView(conversation: $0, dataDirectory: model.dataURL).environment(\.locale, model.config.language.locale) }
        .sheet(item: $discovery) { ConversationDiscovery(kind: $0).environmentObject(model).environment(\.locale, model.config.language.locale) }
        .sheet(isPresented: $showingAccount) { AccountDetailsView().environmentObject(model).environment(\.locale, model.config.language.locale) }
        .confirmationDialog(l("删除「\(removing?.title ?? "")」？"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button(l("删除会话配置"), role: .destructive) {
                if let value = removing { Task { do { try await model.removeConversation(value) } catch { model.report(error) } } }
                removing = nil
            }
        } message: { Text(l("仅删除面板中的会话配置并停止监听，钉钉中的聊天记录和成员保持原状。")) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 4) {
                Image(nsImage: AssistantBrand.appIcon).resizable().interpolation(.high)
                    .frame(width: 40, height: 40).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("DWS").font(.system(size: 21, weight: .bold)).foregroundStyle(AssistantTheme.brandGradient)
                    Text("ASSISTANT").font(.system(size: 9, weight: .semibold, design: .rounded))
                        .tracking(2.4).foregroundStyle(AssistantTheme.secondary)
                }
            }.padding(.horizontal, 8).padding(.top, 36)

            VStack(alignment: .leading, spacing: 6) {
                Text(l("工作空间")).font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AssistantTheme.muted).padding(.horizontal, 16).padding(.bottom, 8)
                ForEach(navigation, id: \.0) { item in
                    Button { model.selection = item.0; query = "" } label: {
                        HStack(spacing: 12) {
                            AssistantGlyph(kind: item.2).frame(width: 24, height: 24)
                                .accessibilityHidden(true)
                            Text(tr(item.1)).font(.system(size: 13, weight: model.selection == item.0 ? .semibold : .regular))
                            Spacer(minLength: 8)
                            if item.0 == "groups" || item.0 == "contacts" {
                                Text("\(model.conversations.filter { $0.kind == (item.0 == "groups" ? .group : .contact) }.count)")
                                    .font(.system(size: 11, weight: .medium)).monospacedDigit()
                                    .foregroundStyle(AssistantTheme.secondary).frame(minWidth: 18, alignment: .trailing)
                            }
                        }.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(model.selection == item.0 ? AssistantTheme.accent : AssistantTheme.secondary)
                            .background(model.selection == item.0 ? AssistantTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer(minLength: 16)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text(l("DWS助手服务 · \(model.stopping ? l("关闭中") : model.personalRunning ? l("已开启") : l("未开启"))"))
                        .font(.system(size: 11, weight: .medium)).lineLimit(1).minimumScaleFactor(0.85)
                    Spacer(minLength: 0)
                    Toggle(l("DWS助手服务"), isOn: Binding(get: { model.personalRunning }, set: { if $0 { model.startPersonal() } else { model.stopPersonal() } }))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .disabled(model.preview || model.needsSetup || model.loggingOut || model.stopping || !model.conversationBusy.isEmpty || model.storageFailure != nil)
                }.help(model.stopping ? l("正在关闭 DWS助手服务…") : model.personalRunning ? l("\(model.listeningCount) 个会话监听中") : l("开启后监听已配置的会话"))
                AssistantDivider()
                Button(action: openAccount) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(model.profile?.name ?? l("当前账号"))
                                .font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(model.profile?.organization ?? "")
                                .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary).lineLimit(1)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium))
                            .foregroundStyle(AssistantTheme.muted).frame(width: 8)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .disabled(model.loggingOut)
                    .help(l("查看账号详情或退出登录"))
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.card, in: RoundedRectangle(cornerRadius: 14))
            Text("v1.0.0").font(.system(size: 10)).foregroundStyle(AssistantTheme.muted)
                .padding(.horizontal, 16).padding(.bottom, 16)
        }.padding(.horizontal, 16).frame(width: 224)
            .background(AssistantTheme.sidebar).foregroundStyle(AssistantTheme.text)
    }

    private func openAccount() {
        showingAccount = true
    }

    private var header: some View {
        HStack(spacing: 9) {
            AssistantGlyph(kind: navigation.first(where: { $0.0 == model.selection })?.2 ?? .overview, size: 19)
                .foregroundStyle(AssistantTheme.accent)
            Text(tr(navigation.first(where: { $0.0 == model.selection })?.1 ?? "概览")).font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(l("个人工作空间")).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal, 24).frame(height: 44).background(AssistantTheme.card)
            .overlay(alignment: .bottom) { AssistantTheme.brandGradient.opacity(0.30).frame(height: 1) }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text(l("你的钉钉个人助手")).font(.system(size: 28, weight: .bold))
                Text(l("为每个群聊和私聊，选择合适的监听与回复方式。")).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                metric(l("已添加群聊"), value: "\(model.conversations.filter { $0.kind == .group }.count)", icon: .groups, note: l("每个群独立开关"))
                metric(l("私聊联系人"), value: "\(model.conversations.filter { $0.kind == .contact }.count)", icon: .contacts, note: l("按联系人配置回复"))
                metric(l("正在监听"), value: "\(model.listeningCount)", symbol: "waveform.path", note: l("\(model.conversations.filter(\.listen).count) 个会话已开启监听配置"))
                metric(l("本次已回复"), value: "\(model.deliveredCount)", symbol: "checkmark.bubble", note: l("\(model.uncertainCount) 条投递待确认"))
            }
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top) {
                        sectionTitle(l("个人回复"), detail: l("使用你的钉钉账号，在原会话中回复"))
                        Spacer()
                        statusPill(model.personalRunning ? l("助手已开启") : l("助手未开启"), color: model.personalRunning ? .green : .gray)
                    }.frame(height: 40, alignment: .topLeading)
                    identityCard(title: l("群聊"), subtitle: l("默认仅自己 @自己 回复，可按群调整触发方式"), icon: .groups, status: l("\(model.conversations.filter { $0.kind == .group && $0.listen }.count) 个已开启"), color: accent)
                    AssistantDivider()
                    identityCard(title: l("私聊"), subtitle: l("按联系人开启监听，可设置为仅接收消息"), icon: .contacts, status: l("\(model.conversations.filter { $0.kind == .contact && $0.listen }.count) 个已开启"), color: accent)
                    Text(l("左下角控制 DWS助手；会话开关仅影响对应的群聊或私聊。"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(22).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).card()
                VStack(alignment: .leading, spacing: 20) {
                    sectionTitle(l("开始使用"), detail: l("配置完成后开启左下角助手"))
                        .frame(height: 40, alignment: .topLeading)
                    step("1", title: model.accountOK ? l("账号已连接") : l("连接账号"), detail: l("查看账号信息与授权状态"), action: openAccount)
                    step("2", title: l("添加会话"), detail: l("选择要监听的群聊或联系人")) { model.selection = "groups" }
                    step("3", title: l("配置 AI"), detail: l("选择 AI 引擎和回复方式")) { model.selection = "groups" }
                }.padding(22).frame(width: 270).frame(maxHeight: .infinity, alignment: .topLeading).card()
            }.fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    sectionTitle(l("最近动态"), detail: l("查看回复结果与 AI 生成、发送耗时"))
                    Spacer()
                    Button { model.selection = "activity" } label: {
                        Text(l("查看全部")).foregroundStyle(accent).padding(.horizontal, 12).frame(minHeight: 32).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                if model.activities.isEmpty { Text(l("尚无运行记录。保存配置或开启助手后，动态会显示在这里。")).foregroundStyle(.secondary).padding(.vertical, 18) }
                ForEach(model.activities.prefix(4)) { row in activityRow(row) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading).card()
        }
    }

    private func conversations(_ kind: ConversationKind) -> some View {
        let items = model.conversations.filter { $0.kind == kind && (query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.stableID.localizedCaseInsensitiveContains(query)) }
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 7) {
                    Text(kind == .group ? l("群聊") : l("私聊")).font(.system(size: 27, weight: .bold))
                    Text(kind == .group ? l("选择要监听的群，用个人身份自动回复。") : l("按联系人设置监听和个人自动回复。")).foregroundStyle(.secondary)
                }
                Spacer()
                Button(kind == .group ? l("添加群聊") : l("添加联系人")) { discovery = kind }
                    .buttonStyle(.borderedProminent).disabled(model.preview || !model.accountOK)
            }
            if !model.personalRunning && items.contains(where: \.listen) {
                banner(l("监听配置已开启。打开左下角的 DWS助手开关后开始接收消息。"), symbol: "power", color: accent)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(l("搜索名称或稳定 ID"), text: $query).textFieldStyle(.plain)
                Spacer(); Text(l("\(items.count) 个会话")).font(.caption).foregroundStyle(.secondary)
            }.padding(12).card()
            if items.isEmpty { emptyState(icon: kind == .group ? .groups : .contacts, title: l("还没有\(tr(kind.title))"), detail: l("添加会话后，可以分别设置监听、回复方式和 AI 引擎。")) }
            ForEach(items) { c in conversationRow(c) }
        }
    }

    private func conversationRow(_ c: Conversation) -> some View {
        let status = model.conversationStatus(c)
        let engine = model.engineSummary(c.agent).components(separatedBy: " · ").map(tr).joined(separator: " · ")
        return HStack(spacing: 16) {
            AssistantGlyph(kind: c.kind == .group ? .groups : .contacts).foregroundStyle(accent)
                .frame(width: 40, height: 40)
                .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(c.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).help(c.title)
                Text(c.stableID).font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled).help(c.stableID)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text(c.autoReply ? (c.kind == .contact ? l("自动回复") : tr(c.trigger.title)) : l("仅监听"))
                    .font(.system(size: 11)).lineLimit(1)
                Text(engine).font(.system(size: 10)).lineLimit(1).help(engine)
                if c.autoReply {
                    Text(c.replyFormat == .aiCard ? l("AI 卡片") : tr(c.replyFormat.title) + " · " + (c.showAITag ? l("AI 角标开") : l("AI 角标关")))
                        .font(.system(size: 10)).lineLimit(1)
                }
                if let duration = model.lastReplyDuration[c.id] {
                    Text(diagnostic(duration)).font(.system(size: 10)).lineLimit(1)
                }
            }.foregroundStyle(.secondary).frame(width: 190, alignment: .leading)
            HStack(spacing: 10) {
                statusPill(status, color: model.replyStates[c.id] != nil ? accent : status == "监听中" ? .green : .gray)
                    .lineLimit(2).frame(width: locale.identifier.hasPrefix("zh") ? 98 : 100, alignment: .leading)
                if c.agent.engine == .codex {
                    Button(l("会话历史")) { history = c }.buttonStyle(.bordered)
                }
                Button(l("配置")) { editing = c }.buttonStyle(.bordered)
                    .disabled(model.conversationBusy.contains(c.id))
                Button(l("删除"), role: .destructive) { removing = c }.buttonStyle(.bordered).tint(.red)
                    .disabled(model.preview || model.stopping || model.conversationBusy.contains(c.id))
                    .help(l("删除面板中的会话配置"))
                Toggle(l("监听"), isOn: Binding(get: { model.config.conversations.first(where: { $0.id == c.id })?.listen ?? false }, set: { enabled in Task { await model.setListening(c.id, enabled: enabled) } }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 11)).fixedSize()
                    .disabled(model.preview || model.stopping || model.conversationBusy.contains(c.id))
            }.fixedSize()
        }.padding(.horizontal, 18).padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading).card()
            .task(id: model.engineMetadataKey(c.agent)) { await model.loadConversationEngineMetadata(c.agent) }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionTitle(l("运行与投递"), detail: l("\(model.uncertainCount) 条未知投递保留在本地，不会自动重发"))
            if !model.recentDeliveries.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(l("最近投递记录")).font(.headline)
                    ForEach(model.recentDeliveries.prefix(10)) { record in
                        HStack { Text(record.date, style: .time).foregroundStyle(.secondary); Text(String(record.id.prefix(12))).font(.caption.monospaced()); Spacer(); Text(tr(record.state.title)).font(.caption) }
                    }
                }.padding(20).card()
            }
            if model.activities.isEmpty {
                emptyState(icon: .activity, title: l("暂无日志"), detail: l("保存配置或开启助手后，连接和投递动态会显示在这里。"))
            } else {
                VStack(alignment: .leading, spacing: 15) {
                    ForEach(model.activities) { activityRow($0) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
                .card()
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func activityRow(_ row: Activity) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(row.date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            Circle().fill(row.level == "错误" ? Color.red : accent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 5)
            Text(diagnostic(row.message)).font(.system(size: 12)).foregroundStyle(AssistantTheme.secondary).textSelection(.enabled); Spacer(minLength: 0)
        }
    }
    private func metric(_ title: String, value: String, symbol: String = "", icon: AssistantIcon.Kind? = nil, note: String) -> some View {
        VStack(alignment: .leading, spacing: 12) { HStack { Text(title).foregroundStyle(.secondary).font(.caption); Spacer(); Group { if let icon { AssistantGlyph(kind: icon, size: 18) } else { Image(systemName: symbol).font(.system(size: 17)) } }.foregroundStyle(accent.opacity(0.7)) }; Text(value).font(.system(size: 34, weight: .semibold, design: .rounded)); Text(note).font(.system(size: 10)).foregroundStyle(.secondary) }.padding(20).frame(maxWidth: .infinity, alignment: .leading).card()
    }
    private func identityCard(title: String, subtitle: String, icon: AssistantIcon.Kind, status: String, color: Color) -> some View {
        HStack(spacing: 12) { AssistantGlyph(kind: icon).foregroundStyle(color).frame(width: 42, height: 42).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 11)); VStack(alignment: .leading, spacing: 5) { Text(title).fontWeight(.semibold); Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary) }; Spacer(); statusPill(status, color: .gray) }
    }
    private func step(_ number: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(number).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                    .frame(width: 29, height: 29).background(accent.opacity(0.08), in: Circle())
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

extension View {
    func card() -> some View { background(AssistantTheme.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(AssistantTheme.border, lineWidth: 1)) }
}
func sectionTitle(_ title: String, detail: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(title).font(.system(size: 16, weight: .semibold)); Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) } }
func statusPill(_ title: String, color: Color) -> some View { let color = color == .gray ? AssistantTheme.secondary : color; return TranslatedText(title).font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.08), in: Capsule()) }
func banner(_ message: String, symbol: String, color: Color) -> some View { Label(message, systemImage: symbol).font(.system(size: 12)).foregroundStyle(color).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)) }
func emptyState(symbol: String = "", icon: AssistantIcon.Kind? = nil, title: String, detail: String) -> some View { VStack(spacing: 13) { Group { if let icon { AssistantGlyph(kind: icon, size: 39) } else { Image(systemName: symbol).font(.system(size: 39)) } }.foregroundStyle(accent.opacity(0.55)); Text(title).font(.headline); Text(detail).font(.callout).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 70).card() }
