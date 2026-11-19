import SwiftUI
import AssistantCore

struct ConversationDiscovery: AssistantLocalizedView {
    @Environment(\.locale) var locale
    @EnvironmentObject var model: AssistantModel
    @Environment(\.dismiss) private var dismiss
    let kind: ConversationKind
    @State private var query = ""
    @State private var items: [DiscoveredConversation] = []
    @State private var cursor: String?
    @State private var cursors = Set<String>()
    @State private var loading = false
    @State private var detail = ""
    @State private var loadedQuery = ""
    @State private var loadedProfile = ""
    @State private var draft: Conversation?
    private var profile: String { model.accountOK ? model.profile?.id ?? "" : "" }
    private var keyword: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var noun: String { kind == .group ? l("群聊") : l("联系人") }

    var body: some View {
        if let draft {
            ConversationEditor(value: draft)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 22)).foregroundStyle(.secondary)
                    TextField(kind == .group ? l("搜索群名称") : l("搜索联系人姓名"), text: $query)
                        .font(.system(size: 20)).textFieldStyle(.plain)
                        .onSubmit { if let first = items.first, loadedQuery == keyword { configure(first) } }
                    if loading { ProgressView().controlSize(.small) }
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain).keyboardShortcut(.cancelAction).help(l("关闭搜索"))
                }.padding(22)
                AssistantDivider()
                if keyword.isEmpty {
                    VStack(spacing: 12) {
                        AssistantGlyph(kind: kind == .group ? .groups : .contacts, size: 34).foregroundStyle(.secondary)
                        Text(l("输入\(noun)名称，选择结果后配置并添加")).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(items) { item in
                                let added = model.conversations.contains { $0.kind == kind && $0.stableID == item.id }
                                Button { configure(item) } label: {
                                    HStack(spacing: 12) {
                                        AssistantGlyph(kind: kind == .group ? .groups : .contacts)
                                            .foregroundStyle(AssistantTheme.accent).frame(width: 38, height: 38)
                                            .background(AssistantTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(item.name).font(.system(size: 14, weight: .medium))
                                            Text(item.id).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if added { Text(l("已添加")).font(.caption).foregroundStyle(.secondary) }
                                        else { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }
                                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(added || loading || loadedQuery != keyword || loadedProfile != profile)
                            }
                            if cursor != nil {
                                Button(l("加载更多")) { Task { await search(more: true) } }.disabled(loading).padding(8)
                            }
                            if !loading && items.isEmpty { Text(detail.isEmpty ? l("没有找到相关\(noun)") : diagnostic(detail)).foregroundStyle(.secondary).padding(.vertical, 52) }
                        }.padding(10)
                    }.frame(height: 310)
                    if !items.isEmpty && !detail.isEmpty { Text(diagnostic(detail)).font(.caption).foregroundStyle(.secondary).padding(.bottom, 12) }
                }
            }.frame(width: 620).background(AssistantTheme.card).foregroundStyle(AssistantTheme.text).tint(AssistantTheme.action)
                .assistantInputFocus()
                .task(id: query) {
                    items = []; cursor = nil; cursors = []; detail = ""
                    guard !keyword.isEmpty else { loading = false; return }
                    loading = true
                    do { try await Task.sleep(nanoseconds: 350_000_000); try Task.checkCancellation(); await search(more: false) }
                    catch { }
                }
        }
    }
    private func configure(_ item: DiscoveredConversation) {
        guard !loading, loadedProfile == profile, loadedQuery == keyword,
              !model.conversations.contains(where: { $0.kind == kind && $0.stableID == item.id }) else { return }
        var value = Conversation(); value.kind = kind; value.profile = profile
        value.stableID = item.id; value.name = item.name
        if kind == .contact { value.trigger = .all }
        draft = value
    }
    private func search(more: Bool) async {
        let p = profile, q = keyword
        guard !p.isEmpty, !q.isEmpty else { loading = false; detail = l("请先登录钉钉"); return }
        guard !more || (loadedProfile == p && loadedQuery == q) else { return }
        loading = true
        do {
            let page = try await model.discover(kind: kind, profile: p, query: q, cursor: more ? cursor : nil)
            try Task.checkCancellation()
            guard p == profile, q == keyword else { return }
            if !more { items = []; cursors = [] }
            var seen = Set(items.map(\.id)); items += page.items.filter { seen.insert($0.id).inserted }
            loadedProfile = p; loadedQuery = q; cursor = page.nextCursor; detail = page.detail
            if let next = cursor, !cursors.insert(next).inserted { cursor = nil }
            loading = false
        } catch {
            guard !Task.isCancelled, p == profile, q == keyword else { return }
            detail = error.localizedDescription; loading = false
        }
    }
}
