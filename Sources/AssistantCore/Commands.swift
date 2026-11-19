import Foundation

public enum ReplyReaction: String {
    case processing = "思考", completed = "对勾", failed = "打叉", uncertain = "迷惑"
}

public enum Commands {
    public static func reaction(_ reaction: ReplyReaction, remove: Bool = false, event: IMEvent, conversation: Conversation, currentSenderID: String, config: AssistantConfig) throws -> CommandSpec {
        guard EventRouting.shouldReply(event, profile: conversation.profile, conversation: conversation, currentSenderID: currentSenderID) else { throw AssistantError.invalid("状态表情不属于已授权的自动回复") }
        try Validation.profile(conversation.profile)
        try Validation.stableID(event.conversationID, name: "原消息会话 ID")
        try Validation.stableID(event.messageID, name: "原消息 ID")
        return try dws(["chat", remove ? "+messages-remove-emoji" : "+messages-add-emoji", "--conversation-id", event.conversationID, "--msg-id", event.messageID, "--emoji", reaction.rawValue, "--profile", conversation.profile, "--format", "json", "--yes"], config: config, timeout: 5)
    }
    public static func dws(_ arguments: [String], config: AssistantConfig, stdin: String? = nil, timeout: TimeInterval = 45, streaming: Bool = false) throws -> CommandSpec {
        CommandSpec(executable: try Executables.resolve("dws", overrides: config.executablePaths), arguments: arguments, stdin: stdin, environment: Executables.environment(overrides: config.executablePaths), timeout: timeout, streaming: streaming)
    }
    public static func selfIdentity(profile: String, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(profile)
        let userID = String(profile.split(separator: ":", maxSplits: 1)[1])
        return try dws(["contact", "user", "search", "--query", userID, "--profile", profile, "--format", "json"], config: config, timeout: 15)
    }
    public static func logout(profile: String, config: AssistantConfig) throws -> CommandSpec {
        // DWS defaults to all accounts when --profile is absent. Always pass
        // the validated, exact corpId:userId of the displayed account.
        try Validation.profile(profile)
        return try dws(["auth", "logout", "--profile", profile], config: config, timeout: 25)
    }
    public static func imageDetails(_ event: IMEvent, profile: String, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(profile); try Validation.stableID(event.conversationID)
        let ids = Array(Set(event.imageMessageIDs)).sorted()
        guard !ids.isEmpty, ids.count <= 5 else { throw AssistantError.invalid("图片消息引用过多") }
        for id in ids { try Validation.stableID(id, name: "图片消息 ID") }
        return try dws(["chat", "+messages-mget", "--msg-ids", ids.joined(separator: ","), "--no-reactions", "--no-threads", "--profile", profile, "--format", "json"], config: config, timeout: 20)
    }
    public static func downloadImage(_ resource: ImageResource, profile: String, directory: URL, index: Int, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(profile)
        for id in [resource.id, resource.messageID, resource.conversationID] { try Validation.stableID(id) }
        guard ["mediaId", "fileId"].contains(resource.type) else { throw AssistantError.invalid("图片资源类型无效") }
        var spec = try dws(["chat", "+messages-resource-download", "--type", resource.type, "--resource-id", resource.id,
            "--message-id", resource.messageID, "--open-conversation-id", resource.conversationID,
            "--output", "source-\(index).bin", "--profile", profile, "--format", "json"], config: config, timeout: 30)
        // Fixed launcher only: external values remain literal argv items.
        // RLIMIT_FSIZE also bounds downloads without a Content-Length header.
        spec.arguments = ["-c", "ulimit -f \(ImageCache.maximumImageBytes / 1024) || exit 1; exec \"$@\"", "dws-image-download", spec.executable] + spec.arguments
        spec.executable = "/bin/bash"; spec.directory = directory.path
        return spec
    }
    public static func listener(_ conversation: Conversation, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(conversation.profile); try Validation.stableID(conversation.stableID)
        var args: [String]
        if conversation.kind == .contact {
            args = ["event", "consume", "user_im_message_receive_o2o", "--open-dingtalk-id", conversation.stableID, "--flatten", "--ephemeral"]
        } else {
            args = ["event", "+listen-im", "--kind", "group", "--chat-id", conversation.stableID, "--events", "message"]
        }
        args += ["--duration", "0", "--max-events", "0", "-f", "ndjson", "--profile", conversation.profile]
        return try dws(args, config: config, timeout: 0, streaming: true)
    }
    public static func mentions(profile: String, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(profile)
        return try dws(["event", "+listen-im", "--kind", "at-me", "--events", "message", "--duration", "0", "--max-events", "0", "-f", "ndjson", "--profile", profile], config: config, timeout: 0, streaming: true)
    }
    public static func cardActions(profile: String, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(profile)
        return try dws(["event", "consume", "user_card_action_triggered", "--flatten", "--ephemeral", "--duration", "0", "--max-events", "0", "-f", "ndjson", "--profile", profile], config: config, timeout: 0, streaming: true)
    }
    public static func send(_ conversation: Conversation, text: String, key: String, config: AssistantConfig, card: AICardReply? = nil) throws -> CommandSpec {
        try Validation.profile(conversation.profile); try Validation.stableID(conversation.stableID)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 32_768 else { throw AssistantError.invalid("回复为空或超过 32 KiB") }
        if conversation.replyFormat == .aiCard {
            let card = try card ?? AICardReply(text: text, key: key, conversation: conversation, conversationID: conversation.kind == .group ? conversation.stableID : "")
            return try dws(["chat", "message", "send-a2ui-card", conversation.kind == .group ? "--conversation-id" : "--open-dingtalk-id", conversation.stableID,
                            "--content", "-", "--summary", AICardReply.summary, "--profile", conversation.profile, "--format", "json", "--yes"],
                           config: config, stdin: card.creationContent, timeout: 90)
        }
        let markdown = conversation.replyFormat == .markdown
        return try dws(["chat", "+messages-send", "--as", "user", "--ai-tag=\(conversation.showAITag)", conversation.kind == .group ? "--group" : "--open-dingtalk-id", conversation.stableID, markdown ? "--markdown" : "--text", "-", "--body-stdin", "--idempotency-key", key, "--wait-delivery", "--profile", conversation.profile, "--format", "json", "--yes"], config: config, stdin: markdown ? AICardReply.textOnlyMarkdown(text) : text, timeout: 90)
    }
    public static func finishCard(_ reference: AICardReference, config: AssistantConfig) throws -> CommandSpec {
        try updateCard(reference, content: reference.finishContent, config: config)
    }
    public static func updateCard(_ reference: AICardReference, content: String, processing: Bool = false, config: AssistantConfig) throws -> CommandSpec {
        try Validation.profile(reference.profile)
        try Validation.stableID(reference.bizID, name: "AI 卡片 ID")
        // Forms are published with FINISH before accepting user input. Their
        // callbacks may update the same card, but must not reopen that stream
        // with INPUTTING. Processing text/animation and tool progress live in
        // the components and do not require the transport to become streaming.
        let flowStatus = processing && reference.interaction == nil ? "INPUTTING" : "FINISH"
        return try dws(["chat", "message", "update-a2ui-card", "--biz-id", reference.bizID, "--content", "-", "--flow-status", flowStatus, "--profile", reference.profile, "--format", "json", "--yes"], config: config, stdin: content, timeout: 45)
    }
    public static func geminiCLI(_ settings: AgentSettings, prompt: String, config: AssistantConfig, fallbackDirectory: URL = AssistantPaths.dataDirectory.appendingPathComponent("agent-workspace"), images: [String] = []) throws -> CommandSpec {
        try Validation.agent(settings)
        guard settings.engine == .gemini else { throw AssistantError.invalid("该引擎必须使用官方 DWS 适配器") }
        let references = images.map { "@" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: " ", with: "\\ ") }.joined(separator: " ")
        var args = ["--prompt", "请根据标准输入中的上下文生成回复。" + (references.isEmpty ? "" : "\n附图：\n" + references), "--output-format", "json", "--approval-mode", settings.permission == .full ? "yolo" : "plan"]
        if !settings.model.isEmpty { args += ["--model", settings.model] }
        for path in settings.additionalDirectories { args += ["--include-directories", path] }
        for path in Set(images.map { URL(fileURLWithPath: $0).deletingLastPathComponent().path }).sorted() { args += ["--include-directories", path] }
        let workdir = try AssistantPaths.agentWorkdir(settings.workdir, fallback: fallbackDirectory)
        return CommandSpec(executable: try Executables.resolve("gemini", overrides: config.executablePaths), arguments: args, stdin: try AgentRules.prompt(prompt, rules: settings.rules), directory: workdir, environment: Executables.environment(overrides: config.executablePaths), timeout: TimeInterval(settings.timeout))
    }
    public static func officialAgent(_ settings: AgentSettings, prompt: String, route: String, bridgePath: String, stateDirectory: String, config: AssistantConfig, images: [String] = [], sessionTitle: String = "", reportProgress: Bool = false) throws -> CommandSpec {
        var settings = settings
        try Validation.agent(settings)
        let authorizedDirectories = settings.authorizedDirectories
        let fallback = URL(fileURLWithPath: stateDirectory, isDirectory: true).appendingPathComponent("workspace", isDirectory: true)
        guard settings.engine != .gemini else { return try geminiCLI(settings, prompt: prompt, config: config, fallbackDirectory: fallback, images: images) }
        settings.workdir = try AssistantPaths.agentWorkdir(settings.workdir, fallback: fallback)
        if settings.engine == .claude || settings.engine == .qoder {
            let defaults = EngineDefaults.read(engine: settings.engine, workdir: settings.workdir)
            if settings.model.isEmpty { settings.model = defaults.model }
            if settings.reasoningEffort == .inherit { settings.reasoningEffort = ReasoningEffort(rawValue: defaults.effort) ?? .inherit }
        }
        try Validation.agent(settings)
        guard FileManager.default.isExecutableFile(atPath: bridgePath) else { throw AssistantError.invalid("官方 DWS 适配包装程序缺失，请重新构建完整应用") }
        let rules = try AgentRules.encodedInstructions(settings.rules)
        var sessionSettings = settings
        sessionSettings.rules = []
        sessionSettings.sessionTitle = ""
        if settings.engine != .custom { sessionSettings.agentCommand = "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        // Only effective instructions affect memory. Editing a disabled rule or
        // regenerating its local UI identifier must not reset an engine session.
        let fingerprint = String(decoding: try encoder.encode(sessionSettings), as: UTF8.self) + (rules.isEmpty ? "" : "|rules-v1:" + rules)
        // Codex keeps one binding per route in the assistant's private store.
        let scope = settings.engine == .codex ? CodexHistory.scope(route: route) : "dashboard-" + Digest.sha256(route + fingerprint)
        let text = settings.engine == .codex ? prompt : try AgentRules.prompt(prompt, rules: settings.rules)
        var payload: [String: Any] = ["channel": settings.engine.channel, "conversation_id": Digest.sha256(route), "scope_id": scope, "text": text,
            "model": settings.model, "workdir": settings.workdir, "additional_directories": settings.additionalDirectories, "state_dir": stateDirectory,
            "authorized_directories": authorizedDirectories,
            "full_permission": settings.permission == .full, "timeout_seconds": settings.timeout,
            "reasoning_effort": settings.engine.supportsReasoning ? settings.reasoningEffort.rawValue : ""]
        if settings.engine == .codex && !rules.isEmpty { payload["custom_rules"] = rules }
        if settings.engine == .codex {
            payload["codex_home"] = CodexHistory.home(stateDirectory: URL(fileURLWithPath: stateDirectory, isDirectory: true)).path
            if reportProgress { payload["report_progress"] = true }
            let customTitle = settings.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            payload["session_title"] = customTitle.isEmpty ? String(sessionTitle.prefix(120)) : customTitle
        }
        if !images.isEmpty { payload["image_paths"] = images }
        if settings.engine == .custom { payload["agent_command"] = settings.agentCommand }
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        return CommandSpec(executable: bridgePath, arguments: [], stdin: String(decoding: data, as: UTF8.self), directory: settings.workdir, environment: Executables.environment(overrides: config.executablePaths), timeout: TimeInterval(settings.timeout + 10))
    }
    public static func finalAnswer(_ result: CommandResult, engine: Engine) throws -> String {
        let obj = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
        if obj?["is_error"] as? Bool == true || obj?["error"] != nil {
            let message: String
            switch obj?["reason"] as? String {
            case "session_resume_failed": message = "历史会话恢复失败，未执行本次请求"
            case "session_busy": message = "历史会话正被其他 Codex 客户端占用，未执行本次请求；请释放该会话后重试"
            case "session_storage_unavailable": message = "无法准备 Codex 专用会话目录，未执行本次请求，请检查本地数据目录"
            case "session_storage_failed": message = "会话绑定保存失败，未执行本次请求，请检查本地数据目录"
            case "engine_settings_failed": message = "无法读取当前引擎设置，未执行本次请求"
            case "engine_timeout": message = "执行超时，已停止本次请求"
            case "cancelled": message = "本次执行已取消"
            case "engine_unavailable": message = "无法启动，请检查是否已安装"
            case "authentication_required": message = "登录已失效，请在引擎中重新登录"
            case "directory_unavailable": message = "授权目录不可用，请检查会话配置"
            case "invalid_request": message = "请求配置无效，请检查会话设置"
            default: message = "执行失败，请检查引擎登录状态和模型配置"
            }
            throw AssistantError.command("\(engine.title)：\(message)")
        }
        _ = try result.checked()
        let answer = obj?[engine == .gemini ? "response" : "result"] as? String
        guard let answer, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, answer.utf8.count <= 32_768 else { throw AssistantError.command("没有取得有效的最终回复，或回复超过 32 KiB") }
        return answer
    }
}
