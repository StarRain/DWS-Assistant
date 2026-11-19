import Foundation

public enum Engine: String, Codable, CaseIterable, Identifiable {
    case codex, claude, qoder, qoderwork, opencode, workbuddy, codebuddy, gemini, pi, custom
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .codex: return "Codex"; case .claude: return "Claude Code"
        case .qoder: return "Qoder"; case .qoderwork: return "QoderWork"
        case .opencode: return "OpenCode"; case .workbuddy: return "WorkBuddy"
        case .codebuddy: return "CodeBuddy"; case .gemini: return "Gemini"
        case .pi: return "Pi"; case .custom: return "自定义 Agent"
        }
    }
    public var executable: String {
        switch self {
        case .claude: return "claude"
        case .qoder, .qoderwork: return "qodercli"
        case .workbuddy, .codebuddy: return "codebuddy"
        default: return rawValue
        }
    }
    public var channel: String { self == .claude ? "claudecode" : rawValue }
    public static var installedCLIEngines: [Engine] { allCases.filter { $0 != .custom } }
    public static var executableNames: [String] { Array(Set(installedCLIEngines.map(\.executable))).sorted() }
    public var usesBridge: Bool { self != .gemini }
    public var supportsReasoning: Bool { [.codex, .claude, .qoder, .qoderwork].contains(self) }
    public var supportsAdditionalDirectories: Bool { [.codex, .claude, .qoder, .qoderwork, .gemini].contains(self) }
}

public enum ExecutionPermission: String, Codable, CaseIterable, Identifiable {
    // Keep the persisted "full" value: for Codex it has always meant auto-review.
    // Full access requires a new, explicit selection; loading old settings never upgrades it.
    case restricted, full, requestApproval, fullAccess
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .restricted: return "只读"
        case .full: return "帮我批准"
        case .requestApproval: return "请求批准"
        case .fullAccess: return "完全访问权限"
        }
    }
    public static func options(for engine: Engine) -> [Self] {
        engine == .codex ? [.restricted, .requestApproval, .full, .fullAccess] : [.restricted, .full]
    }
    public func title(for engine: Engine) -> String {
        if engine == .codex { return title }
        if engine == .gemini { return self == .restricted ? "计划模式（只读）" : "自动执行（YOLO）" }
        if engine == .qoder || engine == .qoderwork || engine == .pi { return self == .restricted ? "禁用工具" : "自动执行（引擎原生）" }
        if [.claude, .workbuddy, .codebuddy].contains(engine) { return self == .restricted ? "引擎默认权限" : "跳过权限询问" }
        return self == .restricted ? "引擎默认权限" : "自动执行（引擎原生）"
    }
    public func detail(for engine: Engine) -> String {
        if engine != .codex { return "使用所选引擎原生的执行权限；授权目录仍限定任务范围。" }
        switch self {
        case .restricted: return "只读访问，不执行构建或文件修改，也不申请扩展权限。"
        case .requestApproval: return "常规操作在工作区沙箱内运行；扩展权限时显示原生审批请求，由你批准本次操作或拒绝。"
        case .full: return "常规操作在工作区沙箱内运行；需要扩展权限时由 Codex 自动审批，被拒绝的操作会停止。"
        case .fullAccess: return "使用 Codex 完整访问模式，可访问工作区外的文件和网络；任务仍须符合你的授权及引擎策略。"
        }
    }
    public var codexMode: String {
        switch self {
        case .restricted: return "read_only"
        case .full: return "auto_review"
        case .requestApproval: return "ask"
        case .fullAccess: return "full_access"
        }
    }
}

public enum ReasoningEffort: String, Codable, CaseIterable, Identifiable {
    case inherit = "", none, minimal, low, medium, high, xhigh, max, ultra
    public var id: String { rawValue }
    public var title: String {
        self == .inherit ? "跟随引擎设置" : rawValue
    }
}

public struct AgentSettings: Codable, Equatable {
    public var engine: Engine = .codex
    public var model = ""
    public var workdir = ""
    public var additionalDirectories: [String] = []
    public var authorizedDirectories: [String] {
        get { ([workdir] + additionalDirectories).filter { !$0.isEmpty } }
        set {
            var seen = Set<String>()
            let paths = newValue.filter { !$0.isEmpty && seen.insert($0).inserted }
            workdir = paths.first ?? ""
            additionalDirectories = Array(paths.dropFirst())
        }
    }
    public var permission: ExecutionPermission = .restricted
    public var timeout: Int = 120
    public var reasoningEffort: ReasoningEffort = .inherit
    public var rules: [AgentRule] = []
    public var sessionTitle = ""
    public var agentCommand = ""
    public init() {}
    private enum CodingKeys: String, CodingKey { case engine, model, workdir, additionalDirectories, authorizedDirectories, permission, timeout, reasoningEffort, rules, sessionTitle, agentCommand }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decode(Engine.self, forKey: .engine)
        model = try values.decode(String.self, forKey: .model)
        if let paths = try values.decodeIfPresent([String].self, forKey: .authorizedDirectories) {
            authorizedDirectories = paths
        } else {
            // Earlier versions populated the user's entire home automatically.
            // Drop that implicit default; retain explicitly added directories.
            let oldWorkdir = try values.decodeIfPresent(String.self, forKey: .workdir) ?? ""
            let extra = try values.decodeIfPresent([String].self, forKey: .additionalDirectories) ?? []
            let implicitHome = FileManager.default.homeDirectoryForCurrentUser.path
            authorizedDirectories = (oldWorkdir == implicitHome ? [] : [oldWorkdir]) + extra
        }
        permission = try values.decode(ExecutionPermission.self, forKey: .permission)
        timeout = try values.decode(Int.self, forKey: .timeout)
        reasoningEffort = try values.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort) ?? .inherit
        rules = try values.decodeIfPresent([AgentRule].self, forKey: .rules) ?? []
        sessionTitle = try values.decodeIfPresent(String.self, forKey: .sessionTitle) ?? ""
        agentCommand = try values.decodeIfPresent(String.self, forKey: .agentCommand) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(engine, forKey: .engine); try values.encode(model, forKey: .model)
        try values.encode(authorizedDirectories, forKey: .authorizedDirectories)
        try values.encode(permission, forKey: .permission)
        try values.encode(timeout, forKey: .timeout)
        if reasoningEffort != .inherit { try values.encode(reasoningEffort, forKey: .reasoningEffort) }
        if !rules.isEmpty { try values.encode(rules, forKey: .rules) }
        if !sessionTitle.isEmpty { try values.encode(sessionTitle, forKey: .sessionTitle) }
        if !agentCommand.isEmpty { try values.encode(agentCommand, forKey: .agentCommand) }
    }
}

public enum ConversationKind: String, Codable, CaseIterable, Identifiable {
    case group, contact
    public var id: String { rawValue }
    public var title: String { self == .group ? "群聊" : "个人联系人" }
}

public enum ReplyTrigger: String, Codable, CaseIterable, Identifiable {
    case all, mentioned, selfMentioned
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "收到消息自动回复"
        case .mentioned: return "仅 @自己 回复"
        case .selfMentioned: return "仅自己 @自己 回复"
        }
    }
    public var detail: String {
        switch self {
        case .all: return "收到他人消息或本人手动 @自己时回复；助手发出的回复会自动过滤。"
        case .mentioned: return "他人或本人 @当前登录账号时回复；助手发出的回复会自动过滤。"
        case .selfMentioned: return "仅当前登录账号本人手动 @自己时回复；他人消息和助手回复不会触发。"
        }
    }
}

public enum ReplyFormat: String, Codable, CaseIterable, Identifiable {
    case text, markdown, aiCard
    public var id: String { rawValue }
    public var title: String {
        switch self { case .text: return "普通文本"; case .markdown: return "Markdown"; case .aiCard: return "AI 卡片" }
    }
}

public struct Conversation: Codable, Identifiable, Equatable {
    public var needsCardEvents: Bool { autoReply && (replyFormat == .aiCard || (agent.engine == .codex && agent.permission == .requestApproval)) }
    public static let defaultCardInteractionTimeout = 60
    public static let cardInteractionTimeoutRange = 10...86_400
    public var id = UUID()
    public var kind: ConversationKind = .group
    public var stableID = ""
    public var name = ""
    public var profile = ""
    public var listen = false
    public var autoReply = false
    public var trigger: ReplyTrigger = .selfMentioned
    public var replyFormat: ReplyFormat = .text
    public var cardInteractionTimeout = Self.defaultCardInteractionTimeout
    public var agent = AgentSettings()
    public var showAITag = true
    public var showReplyStatus = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case id, kind, stableID, name, profile, listen, autoReply, trigger, replyFormat, cardInteractionTimeout, agent, showAITag, showReplyStatus }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(ConversationKind.self, forKey: .kind)
        stableID = try values.decode(String.self, forKey: .stableID)
        name = try values.decode(String.self, forKey: .name)
        profile = try values.decode(String.self, forKey: .profile)
        listen = try values.decode(Bool.self, forKey: .listen)
        autoReply = try values.decode(Bool.self, forKey: .autoReply)
        trigger = try values.decodeIfPresent(ReplyTrigger.self, forKey: .trigger) ?? .selfMentioned
        replyFormat = try values.decodeIfPresent(ReplyFormat.self, forKey: .replyFormat) ?? .text
        cardInteractionTimeout = try values.decodeIfPresent(Int.self, forKey: .cardInteractionTimeout) ?? Self.defaultCardInteractionTimeout
        agent = try values.decode(AgentSettings.self, forKey: .agent)
        showAITag = try values.decodeIfPresent(Bool.self, forKey: .showAITag) ?? true
        showReplyStatus = try values.decodeIfPresent(Bool.self, forKey: .showReplyStatus) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id); try values.encode(kind, forKey: .kind)
        try values.encode(stableID, forKey: .stableID); try values.encode(name, forKey: .name)
        try values.encode(profile, forKey: .profile); try values.encode(listen, forKey: .listen)
        try values.encode(autoReply, forKey: .autoReply); try values.encode(trigger, forKey: .trigger)
        try values.encode(replyFormat, forKey: .replyFormat); try values.encode(agent, forKey: .agent)
        try values.encode(showAITag, forKey: .showAITag); try values.encode(showReplyStatus, forKey: .showReplyStatus)
        // Keep the canonical encoding of existing configurations unchanged, so
        // an upgrade alone does not invalidate already-issued cards.
        if cardInteractionTimeout != Self.defaultCardInteractionTimeout {
            try values.encode(cardInteractionTimeout, forKey: .cardInteractionTimeout)
        }
    }
    public var title: String { name.isEmpty ? stableID : name }
    public var routingKey: String { "\(profile)|\(kind.rawValue)|\(stableID)" }
    public var defaultCodexSessionTitle: String { String("DWS · \(kind == .group ? "群聊" : "私聊") · \(title)".prefix(120)) }
}

public enum AppAppearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String {
        switch self { case .system: return "跟随系统"; case .light: return "浅色"; case .dark: return "深色" }
    }
}

public struct AssistantConfig: Codable, Equatable {
    public var schemaVersion = 1
    public var conversations: [Conversation] = []
    public var executablePaths: [String: String] = [:]
    public var appearance: AppAppearance = .system
    public var language: AppLanguage = .simplifiedChinese
    public var setupCompleted = false
    public init() {}
    private enum CodingKeys: String, CodingKey { case schemaVersion, conversations, executablePaths, appearance, language, setupCompleted }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        conversations = try values.decode([Conversation].self, forKey: .conversations)
        executablePaths = try values.decode([String: String].self, forKey: .executablePaths)
        appearance = try values.decodeIfPresent(AppAppearance.self, forKey: .appearance) ?? .system
        language = try values.decodeIfPresent(AppLanguage.self, forKey: .language) ?? .simplifiedChinese
        // Existing configured workspaces should not be forced through onboarding.
        setupCompleted = try values.decodeIfPresent(Bool.self, forKey: .setupCompleted) ?? !conversations.isEmpty
    }
}

public struct ProfileSummary: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var organization: String
    public init(id: String, name: String, organization: String) { self.id = id; self.name = name; self.organization = organization }
    public var title: String { "\(name) · \(organization)" }
}

public struct DiscoveredConversation: Identifiable, Equatable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct DiscoveryPage {
    public var items: [DiscoveredConversation]
    public var nextCursor: String?
    public var complete: Bool
    public var detail: String
    public init(items: [DiscoveredConversation], nextCursor: String?, complete: Bool, detail: String) {
        self.items = items; self.nextCursor = nextCursor; self.complete = complete; self.detail = detail
    }
}

public enum AssistantError: LocalizedError {
    case invalid(String), command(String), storage(String), cancelled, timedOut, outputLimit
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .command(let s), .storage(let s): return s
        case .cancelled: return "操作已取消"
        case .timedOut: return "操作超时，已请求进程退出"
        case .outputLimit: return "CLI 输出超过上限，已停止处理"
        }
    }
}

public enum Validation {
    public static func cardInteractionTimeout(_ seconds: Int) throws {
        guard Conversation.cardInteractionTimeoutRange.contains(seconds) else { throw AssistantError.invalid("卡片等待超时须在 10–86400 秒之间") }
    }
    public static func stableID(_ value: String, name: String = "稳定 ID") throws {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.count < 512, !value.hasPrefix("-"),
              !value.contains(","), !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) })
        else { throw AssistantError.invalid("\(name) 不能为空，或包含空白、逗号及控制字符") }
    }
    public static func profile(_ value: String) throws {
        try stableID(value, name: "账号 profile")
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else { throw AssistantError.invalid("请绑定明确的 corpId:userId 账号") }
    }
    public static func agent(_ value: AgentSettings) throws {
        guard ExecutionPermission.options(for: value.engine).contains(value.permission) else { throw AssistantError.invalid("此引擎不支持所选执行权限") }
        if value.engine == .custom && value.agentCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AssistantError.invalid("请填写自定义 Agent 的启动命令")
        }
        guard value.engine.supportsAdditionalDirectories || value.additionalDirectories.isEmpty else {
            throw AssistantError.invalid("此引擎仅支持一个工作目录，请移除多余目录")
        }
        var directory: ObjCBool = false
        guard value.authorizedDirectories.count <= 32 else { throw AssistantError.invalid("最多添加 32 个授权目录") }
        for path in value.authorizedDirectories {
            guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw AssistantError.invalid("授权目录必须是已存在的绝对目录") }
            if value.engine == .gemini && path.contains(",") { throw AssistantError.invalid("Gemini 不支持路径中含逗号的授权目录") }
        }
        guard (10...900).contains(value.timeout) else { throw AssistantError.invalid("执行超时须在 10–900 秒之间") }
        guard !value.model.contains("\n") else { throw AssistantError.invalid("模型名称不能包含换行") }
        guard value.sessionTitle.count <= 120, !value.sessionTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw AssistantError.invalid("Codex 会话名称最多 120 字，不能包含换行或控制字符") }
        try AgentRules.validate(value.rules)
    }
    public static func configuration(_ config: AssistantConfig) throws {
        guard config.schemaVersion == 1 else { throw AssistantError.invalid("配置版本不受支持") }
        var keys = Set<String>()
        for c in config.conversations {
            try stableID(c.stableID); try profile(c.profile); try agent(c.agent)
            try cardInteractionTimeout(c.cardInteractionTimeout)
            guard keys.insert(c.routingKey).inserted else { throw AssistantError.invalid("同一账号已添加该会话") }
        }
    }
}
