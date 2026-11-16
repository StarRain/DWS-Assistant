import SwiftUI
import AppKit
import ServiceManagement
import DashboardCore
import Darwin

struct Activity: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var level: String
    var message: String
}

private struct PendingReply {
    let event: IMEvent?
    let cardAction: CardActionJob?
    let receivedAt: Date
    init(event: IMEvent, receivedAt: Date) { self.event = event; self.receivedAt = receivedAt; cardAction = nil }
    init(cardAction: CardActionJob) { event = nil; self.cardAction = cardAction; receivedAt = Date() }
    func key(for conversation: Conversation) -> String {
        cardAction?.key ?? DeliveryLedger.key(identity: "personal", profile: conversation.profile, target: conversation.stableID, messageID: event?.messageID ?? "")
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var config = DashboardConfig()
    @Published var profile: ProfileSummary?
    @Published var accountTitle = "尚未检查"
    @Published var accountDetail = "读取本机 DWS 登录状态后显示账号信息"
    @Published var accountOK = false
    @Published var accountCheckState: DWSAccountCheck.State = .unchecked
    @Published var refreshing = false
    @Published var loggingIn = false
    @Published var loggingOut = false
    @Published var loginText = ""
    @Published var personalRunning = false
    @Published var stopping = false
    @Published var listenerStates: [String: String] = [:]
    @Published var activities: [Activity] = []
    @Published var conversationBusy = Set<UUID>()
    @Published var replyStates: [UUID: String] = [:]
    @Published var lastReplyDuration: [UUID: String] = [:]
    @Published var receivedCount = 0
    @Published var deliveredCount = 0
    @Published var notice: String?
    @Published var selection = "overview"
    @Published var detectedPaths: [String: String] = [:]
    @Published var loginAtStartup = false
    @Published var storageFailure: String?
    @Published private var engineMetadata: [String: EngineMetadata] = [:]
    private var engineMetadataDates: [String: Date] = [:]
    private var readingEngineMetadata = Set<String>()

    let preview: Bool
    let dataURL: URL
    var store: JSONStore?
    private var ledger: DeliveryLedger?
    private var imageCache: ImageCache?
    private var startupTask: Task<Void, Never>?
    private var listenerIdentity: (profile: String, senderID: String)?
    private var listeners: [String: ProcessJob] = [:]
    private var replyTasks: [UUID: Task<Void, Never>] = [:]
    private var replyQueues: [UUID: [PendingReply]] = [:]
    private var feedbackTasks: [UUID: Task<Void, Never>] = [:]
    private var listenerIDs: [String: UUID] = [:]
    private var context: [UUID: [String]] = [:]
    private var receivedKeys = Set<String>()
    private var epoch = UUID()
    private var startedAt = Date()
    private var loginJob: ProcessJob?
    private var retryCounts: [String: Int] = [:]
    private var retryTasks: [String: Task<Void, Never>] = [:]
    private var instanceLock: Int32 = -1
    private var began = false
    private var accountMonitor: Task<Void, Never>?
    private var cardExpiryMonitor: Task<Void, Never>?
    private var accountWatcher: DWSLoginWatcher?
    private var accountRefreshRequested = false
    private let authWatchDirectories: [URL]

    var hasActiveWork: Bool { personalRunning || startupTask != nil || loggingIn || loggingOut || !listeners.isEmpty || !replyTasks.isEmpty || !feedbackTasks.isEmpty }
    var needsSetup: Bool { !preview && (!config.setupCompleted || !dwsInstalled || !accountOK || storageFailure != nil) }
    var dwsInstalled: Bool { detectedPaths["dws"].map { $0 != "未找到" } ?? false }
    var installedEngines: [Engine] { Engine.allCases.filter { detectedPaths[$0.executable].map { $0 != "未找到" } ?? false } }
    var canCompleteSetup: Bool { !preview && !refreshing && !loggingIn && !loggingOut && storageFailure == nil && dwsInstalled && accountOK }
    var conversations: [Conversation] {
        guard let profile else { return [] }
        return config.conversations.filter { $0.profile == profile.id }
    }
    var readyCount: Int { listenerStates.values.filter { $0 == "监听中" }.count }
    var listeningCount: Int { config.conversations.filter { conversationStatus($0) == "监听中" || replyStates[$0.id] != nil }.count }
    func conversationStatus(_ c: Conversation) -> String {
        if conversationBusy.contains(c.id) { return "应用配置中" }
        if !c.listen { return "监听已关闭" }
        if stopping { return "正在停止" }
        if !personalRunning { return "待开启助手服务" }
        if listenerIdentity == nil { return "核验账号中" }
        if let state = replyStates[c.id] { return state }
        let state = listenerStates[c.id.uuidString] ?? "连接中"
        if state == "监听中", c.kind == .group, c.autoReply, c.trigger == .mentioned,
           listenerStates["at|" + c.profile] != "监听中" { return "等待 @ 通道" }
        if state == "监听中", c.autoReply, c.replyFormat == .aiCard,
           listenerStates["card|" + c.profile] != "监听中" { return "等待卡片通道" }
        return state
    }
    var uncertainCount: Int { ledger?.records.values.filter { $0.state == .unknown || $0.state == .sending || $0.state == .accepted }.count ?? 0 }
    var recentDeliveries: [DeliveryRecord] { Array(ledger?.records.values ?? Dictionary<String, DeliveryRecord>().values).sorted { $0.date > $1.date }.prefix(40).map { $0 } }

    init(preview: Bool = false, directory: URL? = nil, authDirectories: [URL]? = nil) {
        self.preview = preview
        dataURL = directory ?? DashboardPaths.dataDirectory
        authWatchDirectories = authDirectories ?? DWSLoginWatcher.defaultDirectories
        do {
            if directory == nil { try DashboardPaths.migrateLegacy(from: DashboardPaths.legacyDirectory, to: dataURL) }
            let store = try JSONStore(directory: dataURL)
            instanceLock = Darwin.open(dataURL.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, 0o600)
            guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else { throw DashboardError.storage("同一数据目录已有一个面板在运行") }
            self.store = store
            config = try store.load("config.json", as: DashboardConfig.self) ?? DashboardConfig()
            try Validation.configuration(config)
            ledger = try DeliveryLedger(store: store)
            imageCache = try ImageCache(directory: dataURL.appendingPathComponent("image-cache", isDirectory: true))
            activities = try store.load("activity.json", as: [Activity].self) ?? []
        } catch { storageFailure = "配置读取失败，已禁止启动和覆盖保存：\(error.localizedDescription)" }
        loginAtStartup = SMAppService.mainApp.status == .enabled
        detectExecutables()
        if preview {
            loadPreview()
            if let i = CommandLine.arguments.firstIndex(of: "--preview-page"), CommandLine.arguments.count > i + 1 { selection = CommandLine.arguments[i + 1] }
        }
    }

    func begin() {
        guard !preview, !began, storageFailure == nil else { return }
        began = true
        accountWatcher = DWSLoginWatcher(directories: authWatchDirectories) { [weak self] in self?.accountFilesChanged() }
        accountWatcher?.start()
        accountMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refreshAccounts()
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

    private func accountFilesChanged() {
        if refreshing || loggingIn || loggingOut { accountRefreshRequested = true; return }
        Task { [weak self] in await self?.refreshAccounts() }
    }

    func log(_ message: String, level: String = "信息") {
        activities.insert(Activity(level: level, message: Redaction.clean(message)), at: 0)
        if activities.count > 500 { activities.removeLast(activities.count - 500) }
        do { try store?.save(activities, to: "activity.json") }
        catch { storageFailure = "日志无法保存：\(error.localizedDescription)"; stopPersonal() }
    }

    func report(_ error: Error) { notice = Redaction.clean(error.localizedDescription); log(notice!, level: "错误") }
    func detectExecutables() {
        detectedPaths = Dictionary(uniqueKeysWithValues: (["dws"] + Engine.allCases.map(\.executable)).map { ($0, (try? Executables.resolve($0, overrides: config.executablePaths)) ?? "未找到") })
    }

    func refreshDWSInstallation() {
        guard !preview else { return }
        let path = (try? Executables.resolve("dws", overrides: config.executablePaths)) ?? "未找到"
        guard detectedPaths["dws"] != path else { return }
        detectedPaths["dws"] = path
        // A newly installed or removed CLI changes whether login can be checked.
        // Repeated installation checks otherwise leave account/engine checks alone.
        accountFilesChanged()
    }

    func engineMetadataKey(_ settings: AgentSettings) -> String {
        [settings.engine.rawValue, settings.workdir, config.executablePaths[settings.engine.executable] ?? ""].joined(separator: "\u{1f}")
    }

    func cachedEngineMetadata(for settings: AgentSettings) -> EngineMetadata? {
        engineMetadata[engineMetadataKey(settings)]
    }

    func rememberEngineMetadata(_ metadata: EngineMetadata, for settings: AgentSettings) {
        let key = engineMetadataKey(settings)
        engineMetadata[key] = metadata; engineMetadataDates[key] = Date()
    }

    func engineSummary(_ settings: AgentSettings) -> String {
        let metadata = engineMetadata[engineMetadataKey(settings)]
        let effective = (metadata ?? EngineMetadata()).effectiveDefaults(for: settings)
        let model = effective.model.nonempty ?? (metadata == nil && !preview ? "读取中…" : "默认模型")
        let effort = effective.effort.nonempty ?? "引擎默认"
        return [settings.engine.title, model, effort].joined(separator: " · ")
    }

    func loadConversationEngineMetadata(_ settings: AgentSettings) async {
        guard !preview else { return }
        let key = engineMetadataKey(settings)
        guard !readingEngineMetadata.contains(key),
              engineMetadataDates[key].map({ Date().timeIntervalSince($0) >= 60 }) ?? true else { return }
        readingEngineMetadata.insert(key)
        defer { readingEngineMetadata.remove(key) }
        do {
            let metadata = try await EngineMetadataReader.read(engine: settings.engine, workdir: settings.workdir, config: config,
                                                              cacheDirectory: dataURL.appendingPathComponent("engine-metadata"))
            try Task.checkCancellation()
            guard key == engineMetadataKey(settings) else { return }
            rememberEngineMetadata(metadata, for: settings)
        } catch {
            guard !Task.isCancelled, key == engineMetadataKey(settings) else { return }
            let defaults = EngineDefaults.read(engine: settings.engine, workdir: settings.workdir)
            var metadata = EngineMetadata(); metadata.defaultModel = defaults.model; metadata.configuredEffort = defaults.effort
            rememberEngineMetadata(metadata, for: settings)
        }
    }

    func refreshAccounts() async {
        guard !preview, !refreshing, !loggingIn, !loggingOut else { return }
        refreshing = true; accountRefreshRequested = false
        defer {
            refreshing = false
            if accountRefreshRequested { accountRefreshRequested = false; accountFilesChanged() }
        }
        detectExecutables()
        guard dwsInstalled else {
            if personalRunning { stopPersonal() }
            profile = nil; accountOK = false; accountCheckState = .unavailable
            accountTitle = "尚未安装 DWS"; accountDetail = "安装官方 DWS 后，返回这里重新检测。"
            return
        }
        do {
            let result = try await ProcessRunner.run(Commands.dws(["auth", "status", "--readonly", "--format", "json"], config: config, timeout: 15))
            try Task.checkCancellation()
            let check = try DWSAccountCheck(result)
            let current = check.profile
            // Close the gate and cancel replies as soon as identity is lost or
            // changes. Do not keep showing the old account while shutdown waits.
            if profile?.id != current?.id {
                if personalRunning || stopping { stopPersonal() }
                context.removeAll(); receivedKeys.removeAll()
            }
            profile = current
            accountOK = current != nil
            accountCheckState = check.state; accountTitle = check.title; accountDetail = check.detail
        } catch {
            guard !Task.isCancelled else { return }
            if personalRunning { stopPersonal() }
            profile = nil; accountOK = false; accountCheckState = .indeterminate
            accountTitle = "登录态读取失败"; accountDetail = Redaction.clean(error.localizedDescription)
        }
        detectExecutables()
    }

    func completeSetup() {
        guard canCompleteSetup else { return }
        do {
            var next = config; next.setupCompleted = true
            try persist(next)
            selection = "overview"
        } catch { report(error) }
    }

    func login() {
        guard !preview, !loggingIn, !loggingOut, !refreshing, dwsInstalled, !accountOK, storageFailure == nil else { return }
        do {
            let job = ProcessJob(try Commands.dws(["auth", "login", "--device"], config: config, timeout: 600, streaming: true))
            loginJob = job; loggingIn = true; loginText = "正在请求设备登录，请按下方 DWS 提示完成授权…\n"
            job.start(onLine: { [weak self] line, _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.loginText = String((self.loginText + Redaction.clean(line) + "\n").suffix(12_000))
                }
            }, completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.loggingIn = false; self.loginJob = nil
                    switch result {
                    case .success(let value): if value.status != 0 { self.loginText += "\n登录流程未完成，请检查上方提示。" }
                    case .failure(let error): self.loginText += "\n" + Redaction.clean(error.localizedDescription)
                    }
                    await self.refreshAccounts()
                }
            })
        } catch { report(error) }
    }
    func cancelLogin() { loginJob?.cancel() }

    func logout() async {
        guard !preview, !loggingOut, !loggingIn, !refreshing, accountOK, let current = profile else { return }
        loggingOut = true
        defer {
            loggingOut = false
            if accountRefreshRequested { accountRefreshRequested = false; accountFilesChanged() }
        }
        stopPersonal()
        do {
            for _ in 0..<150 where stopping { try await Task.sleep(for: .milliseconds(100)) }
            guard !stopping else { throw DashboardError.command("助手尚未完全停止，请稍后重试退出登录") }
            _ = try await ProcessRunner.run(Commands.logout(profile: current.id, config: config)).checked()
            profile = nil; accountOK = false; accountCheckState = .signedOut
            accountTitle = "已退出钉钉登录"; accountDetail = "通过钉钉官方授权重新登录，完成后自动检测结果。"
            loginText = ""; notice = nil
            // Existing conversations and settings remain bound to their account.
            log("已退出当前钉钉账号，助手服务已停止")
        } catch { report(error) }
    }

    func discover(kind: ConversationKind = .group, profile: String, query: String, cursor: String? = nil) async throws -> DiscoveryPage {
        guard !preview else { return DiscoveryPage(items: [], nextCursor: nil, complete: true, detail: "预览模式不访问 DWS") }
        guard accountOK, profile == self.profile?.id else { throw DashboardError.invalid("请先登录当前钉钉账号") }
        try Validation.profile(profile)
        if kind == .contact {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return DiscoveryPage(items: [], nextCursor: nil, complete: true, detail: "请输入联系人姓名") }
            return try JSONOutput.contacts(await ProcessRunner.run(Commands.dws(["contact", "user", "search", "--query", query, "--profile", profile, "--format", "json"], config: config)))
        }
        var args = ["chat", query.isEmpty ? "+my-groups" : "+chat-search", "--limit", query.isEmpty ? "200" : "20", "--profile", profile, "--format", "json"]
        if !query.isEmpty { args += ["--query", query] }
        if let cursor, !cursor.isEmpty { args += ["--cursor", cursor] }
        return try JSONOutput.groups(await ProcessRunner.run(Commands.dws(args, config: config)))
    }

    func persist(_ next: DashboardConfig) throws {
        guard storageFailure == nil, let store else { throw DashboardError.storage(storageFailure ?? "配置存储不可用") }
        try Validation.configuration(next)
        try store.save(next, to: "config.json")
        config = next; detectExecutables()
    }

    func applyAppearance() { NSApp.appearance = config.appearance.nativeAppearance }

    func setAppearance(_ appearance: AppAppearance) {
        do {
            if preview { config.appearance = appearance }
            else { var next = config; next.appearance = appearance; try persist(next) }
            applyAppearance()
        } catch { report(error) }
    }

    func setListening(_ id: UUID, enabled: Bool) async {
        guard var c = config.conversations.first(where: { $0.id == id }) else { return }
        c.listen = enabled
        do { try await saveConversation(c) } catch { report(error) }
    }

    func saveConversation(_ conversation: Conversation) async throws {
        guard !preview, !conversationBusy.contains(conversation.id) else { return }
        guard accountOK, let profile else { throw DashboardError.invalid("请先登录钉钉") }
        var conversation = conversation
        guard conversation.profile.isEmpty || conversation.profile == profile.id,
              config.conversations.first(where: { $0.id == conversation.id }).map({ $0.profile == profile.id }) ?? true else {
            throw DashboardError.invalid("当前账号已变化，请重新打开会话配置")
        }
        conversation.profile = profile.id
        conversationBusy.insert(conversation.id); defer { conversationBusy.remove(conversation.id) }
        let previous = config.conversations.first(where: { $0.id == conversation.id })
        var next = config
        if let i = next.conversations.firstIndex(where: { $0.id == conversation.id }) { next.conversations[i] = conversation }
        else { next.conversations.append(conversation) }
        try Validation.configuration(next)
        if personalRunning && conversation.listen { try preflight(conversation) }
        try persist(next)
        if personalRunning { try await stopConversation(conversation.id, previous: previous) }
        if AgentRules.active(previous?.agent.rules ?? []) != AgentRules.active(conversation.agent.rules) {
            context.removeValue(forKey: conversation.id)
        }
        if personalRunning {
            if personalRunning && conversation.listen {
                startListener(key: conversation.id.uuidString, profile: conversation.profile, spec: try Commands.listener(conversation, config: config), generation: epoch)
            }
            try await synchronizeMentions()
        }
        log("已更新「\(conversation.title)」：监听\(conversation.listen ? "开启" : "关闭")\(personalRunning ? "，已应用" : "，开启 AI 助手后生效")")
    }

    func removeConversation(_ conversation: Conversation) async throws {
        guard !preview, !conversationBusy.contains(conversation.id) else { return }
        conversationBusy.insert(conversation.id); defer { conversationBusy.remove(conversation.id) }
        var next = config; next.conversations.removeAll { $0.id == conversation.id }; try persist(next)
        try await stopConversation(conversation.id, previous: conversation)
        try await synchronizeMentions()
        log("已从本地面板移除「\(conversation.title)」")
    }

    private func preflight(_ c: Conversation) throws {
        guard accountOK, c.profile == profile?.id else { throw DashboardError.invalid("会话不属于当前钉钉账号") }
        _ = try Commands.listener(c, config: config)
        if c.autoReply {
            _ = try Executables.resolve(c.agent.engine.executable, overrides: config.executablePaths)
            if c.agent.engine != .gemini && !FileManager.default.isExecutableFile(atPath: nativeBridgePath()) {
                throw DashboardError.invalid("官方适配包装程序缺失，请运行完整构建脚本")
            }
        }
        try prepareExecutableAliases()
    }

    private func stopConversation(_ id: UUID, previous: Conversation? = nil) async throws {
        let key = id.uuidString
        retryTasks.removeValue(forKey: key)?.cancel()
        if let listener = listeners[key] { listenerStates[key] = "正在停止"; listener.cancel() }
        replyTasks[id]?.cancel()
        if let c = previous ?? config.conversations.first(where: { $0.id == id }) {
            for pending in replyQueues[id, default: []] {
                try ledger?.mark(pending.key(for: c), .cancelled)
            }
        }
        replyQueues.removeValue(forKey: id)
        for _ in 0..<100 where listeners[key] != nil || replyTasks[id] != nil { try await Task.sleep(for: .milliseconds(50)) }
        guard listeners[key] == nil, replyTasks[id] == nil else { throw DashboardError.command("旧监听仍在停止，请稍后重试此会话") }
        listenerStates[key] = "已停止"; replyStates.removeValue(forKey: id)
    }

    private func synchronizeMentions() async throws {
        let profiles = personalRunning ? Set(conversations.filter { $0.listen && $0.kind == .group && $0.autoReply }.map(\.profile)) : []
        for key in Set(listeners.keys).union(retryTasks.keys) where key.hasPrefix("at|") && !profiles.contains(String(key.dropFirst(3))) {
            retryTasks.removeValue(forKey: key)?.cancel()
            listenerStates[key] = "正在停止"; listeners[key]?.cancel()
        }
        for profile in profiles {
            let key = "at|" + profile
            for _ in 0..<100 where listeners[key] != nil && listenerStates[key] == "正在停止" { try await Task.sleep(for: .milliseconds(50)) }
            if personalRunning && listeners[key] == nil && retryTasks[key] == nil && config.conversations.contains(where: { $0.profile == profile && $0.listen && $0.kind == .group && $0.autoReply }) {
                startListener(key: key, profile: profile, spec: try Commands.mentions(profile: profile, config: config), generation: epoch)
            }
        }
        try await synchronizeCardActions()
    }

    private func synchronizeCardActions() async throws {
        let profiles = personalRunning ? Set(conversations.filter { $0.listen && $0.autoReply && $0.replyFormat == .aiCard }.map(\.profile)) : []
        for key in Set(listeners.keys).union(retryTasks.keys) where key.hasPrefix("card|") && !profiles.contains(String(key.dropFirst(5))) {
            retryTasks.removeValue(forKey: key)?.cancel()
            listenerStates[key] = "正在停止"; listeners[key]?.cancel()
        }
        for profile in profiles {
            let key = "card|" + profile
            for _ in 0..<100 where listeners[key] != nil && listenerStates[key] == "正在停止" { try await Task.sleep(for: .milliseconds(50)) }
            if personalRunning && listeners[key] == nil && retryTasks[key] == nil && config.conversations.contains(where: { $0.profile == profile && $0.listen && $0.autoReply && $0.replyFormat == .aiCard }) {
                startListener(key: key, profile: profile, spec: try Commands.cardActions(profile: profile, config: config), generation: epoch)
            }
        }
    }

    func stopAll() async -> Bool {
        stopPersonal(); cancelLogin()
        for _ in 0..<150 where stopping || loggingIn || loggingOut { try? await Task.sleep(for: .milliseconds(100)) }
        let complete = !stopping && !loggingIn && !loggingOut
        if complete { log("AI 助手已关闭") }
        else { notice = "停止尚未全部确认，请稍后再检查。" }
        return complete
    }

    func startPersonal() {
        guard !preview, storageFailure == nil, !personalRunning, startupTask == nil, !stopping, conversationBusy.isEmpty, listeners.isEmpty, replyTasks.isEmpty else { return }
        notice = nil
        do {
            guard !needsSetup, accountOK, let profile, !refreshing, !loggingOut else { throw DashboardError.invalid("请先完成钉钉登录") }
            _ = try listenerPlans()
            let identityCommand = try Commands.selfIdentity(profile: profile.id, config: config)
            epoch = UUID(); startedAt = Date(); personalRunning = true; retryCounts = [:]; listenerStates = [:]
            listenerIdentity = nil
            let generation = epoch
            startupTask = Task { [weak self] in
                guard let self else { return }
                defer { self.startupTask = nil; self.finishStopping() }
                do {
                    let result = try await ProcessRunner.run(identityCommand)
                    try Task.checkCancellation()
                    guard self.personalRunning, self.epoch == generation, self.profile?.id == profile.id,
                          self.accountOK, self.storageFailure == nil else { throw DashboardError.cancelled }
                    let userID = String(profile.id.split(separator: ":", maxSplits: 1)[1])
                    let senderID = try JSONOutput.selfSenderID(result, userID: userID)
                    // Re-read configuration after the lookup: edits made while
                    // starting must not resurrect a disabled or removed listener.
                    let plans = try self.listenerPlans()
                    self.listenerIdentity = (profile.id, senderID)
                    self.startedAt = Date()
                    for (key, account, spec) in plans { self.startListener(key: key, profile: account, spec: spec, generation: generation) }
                    self.startCardExpiryMonitor(generation: generation)
                    self.log("当前账号消息身份已核验；手动 @自己可触发回复，助手回复不会重复触发")
                } catch {
                    guard self.epoch == generation else { return }
                    self.stopPersonal()
                    self.report(error)
                }
            }
            log("AI 助手启动中：正在核验当前账号消息身份")
        } catch { report(error) }
    }

    private func listenerPlans() throws -> [(String, String, CommandSpec)] {
        try Validation.configuration(config)
        let enabled = conversations.filter(\.listen)
        guard !enabled.isEmpty else { throw DashboardError.invalid("请先为至少一个群或个人联系人开启监听") }
        var plans: [(String, String, CommandSpec)] = []
        for c in enabled {
            try preflight(c)
            plans.append((c.id.uuidString, c.profile, try Commands.listener(c, config: config)))
        }
        for profile in Set(enabled.filter { $0.kind == .group && $0.autoReply }.map(\.profile)) {
            plans.append(("at|" + profile, profile, try Commands.mentions(profile: profile, config: config)))
        }
        for profile in Set(enabled.filter { $0.autoReply && $0.replyFormat == .aiCard }.map(\.profile)) {
            plans.append(("card|" + profile, profile, try Commands.cardActions(profile: profile, config: config)))
        }
        return plans
    }

    private func startListener(key: String, profile: String, spec: CommandSpec, generation: UUID) {
        guard personalRunning, epoch == generation, listenerIdentity?.profile == profile else { return }
        let token = UUID(); listenerIDs[key] = token
        let job = ProcessJob(spec); listeners[key] = job; listenerStates[key] = "连接中"
        job.start(onLine: { [weak self] line, isError in
            Task { @MainActor in
                guard let self, self.epoch == generation, self.listenerIDs[key] == token, self.personalRunning, self.listenerStates[key] != "正在停止" else { return }
                if isError {
                    if line.contains("[event] ready") { self.listenerStates[key] = "监听中"; self.log("事件通道已就绪") }
                    else if line.localizedCaseInsensitiveContains("error") { self.log(line, level: "错误") }
                } else if key == "card|" + profile {
                    do { self.receiveCardAction(try CardActionEvent(line: line), profile: profile) }
                    catch {
                        if line.contains("user_card_action_triggered") {
                            self.log("卡片操作事件未处理：\(Redaction.clean(error.localizedDescription))", level: "提示")
                        }
                    }
                } else if let event = try? IMEvent(line: line) { self.receive(event, profile: profile) }
            }
        }, completion: { [weak self] result in
            Task { @MainActor in
                guard let self, self.listenerIDs[key] == token else { return }
                self.listeners.removeValue(forKey: key)
                if self.epoch != generation || !self.personalRunning || self.listenerStates[key] == "正在停止" {
                    self.listenerStates[key] = "已停止"; self.finishStopping(); return
                }
                self.listenerStates[key] = "连接已结束"
                let diagnostic: String
                switch result {
                case .success(let r): diagnostic = r.stderr + "\n" + r.stdout
                case .failure(let e): diagnostic = e.localizedDescription
                }
                self.log("事件通道退出：\(Redaction.clean(diagnostic))", level: "错误")
                // Retry only an explicit retryable DWS error; no error-code guessing.
                let error = (try? JSONSerialization.jsonObject(with: Data(diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).utf8))) as? [String: Any]
                let detail = error?["error"] as? [String: Any] ?? error ?? [:]
                let count = self.retryCounts[key, default: 0]
                if detail["retryable"] as? Bool == true, count < 2 {
                    self.retryCounts[key] = count + 1
                    let delay = min(60.0, max(3.0, (detail["retry_after"] as? Double) ?? 5 * Double(count + 1)))
                    self.listenerStates[key] = "\(Int(delay)) 秒后重试"
                    self.retryTasks[key] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        guard !Task.isCancelled, self?.listenerIDs[key] == token else { return }
                        self?.retryTasks.removeValue(forKey: key)
                        self?.startListener(key: key, profile: profile, spec: spec, generation: generation)
                    }
                }
            }
        })
    }

    func stopPersonal() {
        personalRunning = false; epoch = UUID(); listenerIdentity = nil
        cardExpiryMonitor?.cancel(); cardExpiryMonitor = nil
        stopping = startupTask != nil || !listeners.isEmpty || !replyTasks.isEmpty || !feedbackTasks.isEmpty
        startupTask?.cancel()
        for task in retryTasks.values { task.cancel() }; retryTasks.removeAll()
        for job in listeners.values { job.cancel() }
        for task in replyTasks.values { task.cancel() }
        for (id, queue) in replyQueues {
            guard let c = config.conversations.first(where: { $0.id == id }) else { continue }
            for event in queue {
                do { try ledger?.mark(event.key(for: c), .cancelled) } catch { storageFailure = "取消记录无法保存" }
            }
        }
        replyQueues.removeAll(); context.removeAll()
        for key in listenerStates.keys { listenerStates[key] = stopping ? "正在停止" : "已停止" }
        finishStopping()
    }
    private func finishStopping() { if startupTask == nil && listeners.isEmpty && replyTasks.isEmpty && feedbackTasks.isEmpty { stopping = false } }

    private func startCardExpiryMonitor(generation: UUID) {
        cardExpiryMonitor?.cancel()
        cardExpiryMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.personalRunning == true, self?.epoch == generation else { return }
                self?.closeExpiredCards()
                let delay = self?.nextCardExpiryDelay() ?? 30
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
        }
    }

    func nextCardExpiryDelay(now: Date = Date()) -> TimeInterval {
        let next = ledger?.records.values.compactMap { record -> Date? in
            guard record.state == .accepted, record.card?.profile == profile?.id,
                  let interaction = record.card?.interaction, !interaction.consumed, interaction.expiresAt > now else { return nil }
            return interaction.expiresAt
        }.min()
        return min(30, max(0.1, next?.timeIntervalSince(now) ?? 30))
    }

    // Called at service start as well as periodically, so cards that expired
    // while the app was closed are handled without restarting their AI tasks.
    func closeExpiredCards(now: Date = Date()) {
        guard personalRunning, !stopping, storageFailure == nil, accountOK,
              let profile, listenerIdentity?.profile == profile.id, let ledger else { return }
        let expired = ledger.records.values.filter {
            $0.state == .accepted && $0.card?.profile == profile.id && $0.card?.interaction?.consumed == false &&
            ($0.card?.interaction?.expiresAt ?? .distantFuture) <= now
        }.sorted { $0.date < $1.date }
        for record in expired {
            guard let c = config.conversations.first(where: { $0.id.uuidString == record.route && $0.profile == profile.id }),
                  !conversationBusy.contains(c.id), replyTasks[c.id] == nil, replyQueues[c.id, default: []].isEmpty else { continue }
            do {
                guard let job = try ledger.reserveExpiredCard(recordID: record.id, conversation: c, now: now) else { continue }
                replyQueues[c.id, default: []].append(PendingReply(cardAction: job))
                processNext(c.id)
            } catch { report(error); stopPersonal(); return }
        }
    }

    private func receive(_ event: IMEvent, profile: String) {
        guard personalRunning, storageFailure == nil, profile == self.profile?.id, event.isMessage, !event.messageID.isEmpty else { return }
        guard let identity = listenerIdentity, identity.profile == profile,
              EventRouting.isIncoming(event, currentSenderID: identity.senderID) else { return }
        if let time = event.time, time < startedAt.addingTimeInterval(-5) { return }
        for c in config.conversations where !conversationBusy.contains(c.id) && EventRouting.matches(event, profile: profile, conversation: c) {
            if event.senderID == identity.senderID, ledger?.isReplyEcho(event, conversation: c) == true { continue }
            let key = DeliveryLedger.key(identity: "personal", profile: profile, target: c.stableID, messageID: event.messageID)
            if receivedKeys.insert(key).inserted { receivedCount += 1; log("「\(c.title)」收到新消息") }
            if receivedKeys.count > 10_000 { receivedKeys.removeAll(keepingCapacity: true) }
            guard EventRouting.shouldReply(event, profile: profile, conversation: c) else { continue }
            guard replyQueues[c.id, default: []].count < 3 else { log("「\(c.title)」回复队列已满，本条未安排回复", level: "提示"); continue }
            do {
                guard try ledger?.reserve(key, route: c.id.uuidString) == true else { continue }
                replyQueues[c.id, default: []].append(PendingReply(event: event, receivedAt: Date()))
                if replyTasks[c.id] == nil { processNext(c.id) }
            } catch { report(error); stopPersonal() }
        }
    }

    private func receiveCardAction(_ event: CardActionEvent, profile: String) {
        guard personalRunning, !stopping, storageFailure == nil, profile == self.profile?.id,
              listenerIdentity?.profile == profile, event.time >= startedAt.addingTimeInterval(-5),
              let ledger else { return }
        // The official personal event stream is scoped to the authenticated
        // user's actions. Do not compare its numeric uid to a corp userId.
        guard let record = ledger.records.values.first(where: {
            $0.state == .accepted && $0.card?.profile == profile && $0.card?.bizID == event.bizID &&
            $0.card?.interaction?.token == event.token && $0.card?.interaction?.consumed == false
        }), let c = config.conversations.first(where: { $0.id.uuidString == record.route && $0.profile == profile }),
              !conversationBusy.contains(c.id) else { return }
        guard replyQueues[c.id, default: []].count < 3 else {
            log("「\(c.title)」正在处理其他请求，请稍后重新提交卡片", level: "提示"); return
        }
        do {
            guard let job = try ledger.reserveCardAction(event, recordID: record.id, conversation: c, currentSenderID: listenerIdentity?.senderID) else { return }
            replyQueues[c.id, default: []].append(PendingReply(cardAction: job))
            receivedCount += 1
            log("「\(c.title)」卡片\(job.action == "cancel" ? "取消" : "提交")已接收")
            if replyTasks[c.id] == nil { processNext(c.id) }
        } catch { log("「\(c.title)」卡片未处理：\(Redaction.clean(error.localizedDescription))", level: "提示") }
    }

    private func processCardAction(_ job: CardActionJob, conversation c: Conversation, receivedAt: Date) {
        let id = c.id, generation = epoch
        replyTasks[id] = Task { [weak self] in
            guard let self else { return }
            // reserveCardAction already validates the submission deadline.
            // Once accepted, execution uses the engine timeout, not the old
            // time limit for choosing an option on the form.
            let expiring = job.action == "expire"
            var processingAccepted = false, resultAttempted = false, networkAttempted = false
            var liveProgress: CardProgressUpdates?
            defer {
                self.replyStates.removeValue(forKey: id)
                self.replyTasks.removeValue(forKey: id); self.finishStopping()
                if self.epoch == generation { self.processNext(id) }
            }
            @MainActor func checkCurrent() throws {
                try Task.checkCancellation()
                guard self.personalRunning, self.epoch == generation, self.storageFailure == nil,
                      self.accountOK, self.profile?.id == c.profile,
                      self.config.conversations.first(where: { $0.id == id }) == c,
                      job.reference.interaction?.configuration == (try CardInteraction.fingerprint(c)) else { throw DashboardError.cancelled }
            }
            do {
                try checkCurrent()
                let cancelling = job.action == "cancel"
                self.replyStates[id] = expiring ? "关闭过期卡片中" : cancelling ? "取消卡片中" : "处理卡片中"
                let content = try AICardReply.statusContent(job.reference, status: expiring ? "已过期，未执行任务。请发送新消息重新发起。" : cancelling ? "已取消，未执行任务。" : "处理中，请稍候…")
                let update = try Commands.updateCard(job.reference, content: content, processing: !cancelling && !expiring, config: self.config)
                try self.ledger?.mark(job.key, .sending); networkAttempted = true
                let receipt = try await ProcessRunner.run(update)
                guard try AICardReply.updateAccepted(receipt, reference: job.reference) else { throw DashboardError.command("卡片更新结果待确认，未启动任务") }
                if cancelling || expiring {
                    var reference = job.reference; reference.interaction = nil; reference.finishContent = content
                    try self.ledger?.attachCard(reference, to: job.key)
                    try self.ledger?.mark(job.key, .accepted)
                    self.log("「\(c.title)」卡片已\(expiring ? "过期" : "取消")，未启动 AI")
                    return
                }
                processingAccepted = true
                try checkCurrent()
                try self.ledger?.mark(job.key, .generating)
                self.replyStates[id] = "AI 生成中"
                let start = Date()
                let prompt = try job.prompt(context: c.agent.engine == .gemini ? self.context[id, default: []] : [])
                var spec = try Commands.officialAgent(c.agent, prompt: prompt, route: c.routingKey,
                    bridgePath: self.nativeBridgePath(), stateDirectory: self.dataURL.appendingPathComponent("agent-sessions").path, config: self.config, sessionTitle: c.defaultCodexSessionTitle, reportProgress: true)
                let enginePath = spec.environment?["PATH"] ?? ""
                spec.environment?["PATH"] = self.dataURL.appendingPathComponent("bin").path + ":" + enginePath
                let updates = CardProgressUpdates(reference: job.reference, config: self.config, checkCurrent: checkCurrent)
                liveProgress = updates
                let result = try await updates.run(spec)
                self.recordAgentDiagnostics(result, conversation: c)
                let answer = try Commands.finalAnswer(result, engine: c.agent.engine)
                let generationSeconds = Date().timeIntervalSince(start)
                try checkCurrent()
                let card = try AICardReply(text: answer, key: job.key, conversation: c,
                    conversationID: job.reference.interaction?.conversationID ?? "", surfaceID: job.reference.surfaceID, progress: updates.snapshot)
                let reference = card.replacing(job.reference, conversation: c)
                try self.ledger?.attachCard(reference, to: job.key)
                try self.ledger?.prepareReplyEcho(card.body, conversation: c, key: job.key)
                try self.ledger?.mark(job.key, .sending)
                self.replyStates[id] = "更新卡片中"; resultAttempted = true
                let final = try await ProcessRunner.run(Commands.updateCard(reference, content: card.replacementContent, config: self.config))
                guard try AICardReply.updateAccepted(final, reference: reference) else { throw DashboardError.command("卡片结果待确认，不会重新执行") }
                try self.ledger?.mark(job.key, .accepted)
                if card.interaction != nil { self.startCardExpiryMonitor(generation: generation) }
                self.lastReplyDuration[id] = "最近提交 \(String(format: "%.1f", Date().timeIntervalSince(receivedAt))) 秒"
                self.context[id, default: []] += ["用户提交卡片：\(String(job.submission.prefix(3000)))", "助手：\(String(card.body.prefix(3000)))"]
                self.context[id] = Array(self.context[id, default: []].suffix(6))
                self.log("「\(c.title)」原卡片已更新 · AI 生成 \(String(format: "%.1f", generationSeconds)) 秒")
            } catch {
                if liveProgress?.uncertain == true { resultAttempted = true }
                var state: DeliveryRecord.State = networkAttempted ? .unknown : Task.isCancelled ? .cancelled : .failed
                // An accepted progress update followed by a known generation
                // failure can be closed. Never write again after an uncertain
                // final update, or after service/configuration cancellation.
                if processingAccepted && !resultAttempted && !Task.isCancelled && self.personalRunning && self.epoch == generation,
                   self.config.conversations.first(where: { $0.id == id }) == c {
                    do {
                        let content = try AICardReply.statusContent(job.reference, status: "处理失败，未自动重试。请查看面板日志或发送新消息。", progress: liveProgress?.snapshot ?? .init())
                        let result = try await ProcessRunner.run(Commands.updateCard(job.reference, content: content, config: self.config))
                        if try AICardReply.updateAccepted(result, reference: job.reference) {
                            var reference = job.reference; reference.interaction = nil; reference.finishContent = content
                            try self.ledger?.attachCard(reference, to: job.key); state = .accepted
                        }
                    } catch { /* Retain uncertainty; do not retry. */ }
                }
                do { try self.ledger?.mark(job.key, state) }
                catch { self.storageFailure = "卡片交互记录保存失败"; self.stopPersonal() }
                self.log("「\(c.title)」卡片处理已停止：\(Redaction.clean(error.localizedDescription))", level: "提示")
            }
        }
    }

    private func processNext(_ id: UUID) {
        guard personalRunning, let c = config.conversations.first(where: { $0.id == id }), c.listen, c.autoReply,
              var queue = replyQueues[id], !queue.isEmpty else { return }
        let pending = queue.removeFirst(); replyQueues[id] = queue
        if let action = pending.cardAction {
            processCardAction(action, conversation: c, receivedAt: pending.receivedAt)
            return
        }
        guard let event = pending.event else { return }
        let generation = epoch
        let key = DeliveryLedger.key(identity: "personal", profile: c.profile, target: c.stableID, messageID: event.messageID)
        if event.senderID == listenerIdentity?.senderID, ledger?.isReplyEcho(event, conversation: c) == true {
            do { try ledger?.mark(key, .cancelled) } catch { report(error); stopPersonal() }
            processNext(id); return
        }
        replyTasks[id] = Task { [weak self] in
            guard let self else { return }
            var attemptedSend = false
            var progressCard: AICardReference?
            var liveProgress: CardProgressUpdates?
            var updateInFlight = false
            var sendSeconds: TimeInterval = 0
            var terminal: ReplyReaction?
            var imageLease: ImageCacheLease?
            let feedback = c.showReplyStatus && !event.conversationID.isEmpty
            // Feedback runs beside generation and never delays sending the answer.
            let processing = feedback ? Task { await self.changeReaction(.processing, event: event, conversation: c) } : nil
            defer {
                if let imageLease {
                    do { try self.imageCache?.release(imageLease) }
                    catch { self.log("图片临时缓存清理失败，已保留空间占用额度", level: "错误") }
                }
                if let processing { self.finishReactions(processing: processing, terminal: terminal, event: event, conversation: c) }
                self.replyStates.removeValue(forKey: id)
                self.replyTasks.removeValue(forKey: id); self.finishStopping()
                if generation == self.epoch { self.processNext(id) }
            }
            @MainActor func checkCurrent() throws {
                try Task.checkCancellation()
                guard self.personalRunning, self.epoch == generation, self.storageFailure == nil,
                      self.accountOK, self.profile?.id == c.profile,
                      let identity = self.listenerIdentity, identity.profile == c.profile,
                      EventRouting.isIncoming(event, currentSenderID: identity.senderID),
                      let current = self.config.conversations.first(where: { $0.id == id }), current == c,
                      EventRouting.shouldReply(event, profile: c.profile, conversation: current) else { throw DashboardError.cancelled }
            }
            do {
                try checkCurrent()
                if c.replyFormat == .aiCard {
                    let placeholder = try AICardReply(text: event.imageMessageIDs.isEmpty ? "思考中…" : "正在读取图片…",
                        key: key, conversation: c, conversationID: event.conversationID, processing: true)
                    try self.ledger?.attachCard(placeholder.pendingReference(conversation: c), to: key)
                    try self.ledger?.prepareReplyEcho(placeholder.body, conversation: c, key: key)
                    try self.ledger?.mark(key, .sending)
                    self.replyStates[id] = "创建处理卡片"; attemptedSend = true
                    let sendStart = Date()
                    let receipt = try await ProcessRunner.run(Commands.send(c, text: placeholder.body, key: key, config: self.config, card: placeholder))
                    sendSeconds += Date().timeIntervalSince(sendStart)
                    let reference = try placeholder.reference(from: receipt, conversation: c)
                    try self.ledger?.attachCard(reference, to: key)
                    try self.ledger?.rememberSentMessages(receipt, conversation: c, key: key)
                    progressCard = reference
                    try checkCurrent()
                    // Only start work after the server has accepted this exact
                    // placeholder. Never create a second card after uncertainty.
                    try self.ledger?.mark(key, .generating)
                }
                var images: [String] = []
                if !event.imageMessageIDs.isEmpty {
                    self.replyStates[id] = "读取图片中"
                    let details = try await ProcessRunner.run(Commands.imageDetails(event, profile: c.profile, config: self.config))
                    let resources = try IncomingImages.resources(details, event: event)
                    guard let cache = self.imageCache else { throw DashboardError.storage("图片缓存不可用") }
                    let lease = try cache.reserve(count: resources.count); imageLease = lease
                    for (index, resource) in resources.enumerated() {
                        try Task.checkCancellation()
                        let download = try await ProcessRunner.run(Commands.downloadImage(resource, profile: c.profile, directory: lease.directory, index: index, config: self.config))
                        guard download.status == 0 else { throw DashboardError.command("图片下载失败或超过 8 MB 限制") }
                        images.append(try cache.image(from: download, resource: resource, index: index, lease: lease))
                    }
                    if let reference = progressCard {
                        try checkCurrent()
                        let stage = try AICardReply(text: "图片已读取，AI 正在处理…", key: key, surfaceID: reference.surfaceID, processing: true)
                        try self.ledger?.prepareReplyEcho(stage.body, conversation: c, key: key)
                        try self.ledger?.mark(key, .sending); updateInFlight = true
                        let receipt = try await ProcessRunner.run(Commands.updateCard(reference, content: stage.replacementContent, processing: true, config: self.config))
                        guard try AICardReply.updateAccepted(receipt, reference: reference) else { throw DashboardError.command("处理状态更新待确认，未启动 AI") }
                        updateInFlight = false
                        try self.ledger?.mark(key, .generating)
                    }
                }
                try checkCurrent()
                self.replyStates[id] = "AI 生成中"
                let generationStart = Date()
                let prompt = EventRouting.prompt(event: event, context: c.agent.engine == .gemini ? self.context[id, default: []] : [], format: c.replyFormat, images: images)
                var spec = try Commands.officialAgent(c.agent, prompt: prompt, route: c.routingKey, bridgePath: self.nativeBridgePath(), stateDirectory: self.dataURL.appendingPathComponent("agent-sessions").path, config: self.config, images: images, sessionTitle: c.defaultCodexSessionTitle, reportProgress: c.replyFormat == .aiCard)
                let oldPath = spec.environment?["PATH"] ?? ""
                spec.environment?["PATH"] = self.dataURL.appendingPathComponent("bin").path + ":" + oldPath
                let result: CommandResult
                if let reference = progressCard {
                    let updates = CardProgressUpdates(reference: reference, config: self.config, checkCurrent: checkCurrent)
                    liveProgress = updates
                    result = try await updates.run(spec)
                } else { result = try await ProcessRunner.run(spec) }
                self.recordAgentDiagnostics(result, conversation: c)
                let answer = try Commands.finalAnswer(result, engine: c.agent.engine)
                let generationSeconds = Date().timeIntervalSince(generationStart)
                try checkCurrent()
                let card = c.replyFormat == .aiCard ? try AICardReply(text: answer, key: key, conversation: c, conversationID: event.conversationID, surfaceID: progressCard?.surfaceID, progress: liveProgress?.snapshot ?? .init()) : nil
                if card?.interaction != nil {
                    for _ in 0..<100 where self.listenerStates["card|" + c.profile] == "连接中" { try await Task.sleep(for: .milliseconds(50)) }
                    try checkCurrent()
                    guard self.listenerStates["card|" + c.profile] == "监听中" else { throw DashboardError.command("交互卡片通道未就绪，请检查日志后重试") }
                }
                let sendStart = Date()
                var confirmed = false, cardAccepted = false
                if let card {
                    guard let original = progressCard else { throw DashboardError.invalid("缺少原处理卡片，禁止重复创建") }
                    let reference = card.replacing(original, conversation: c)
                    try self.ledger?.attachCard(reference, to: key)
                    try self.ledger?.prepareReplyEcho(card.body, conversation: c, key: key)
                    try self.ledger?.mark(key, .sending); updateInFlight = true
                    self.replyStates[id] = "更新卡片中"
                    let update = try await ProcessRunner.run(Commands.updateCard(reference, content: card.replacementContent, config: self.config))
                    cardAccepted = try AICardReply.updateAccepted(update, reference: reference)
                    guard cardAccepted else { throw DashboardError.command("卡片结果更新待确认，不会重复发送") }
                    updateInFlight = false
                } else {
                    let send = try Commands.send(c, text: answer, key: key, config: self.config)
                    try self.ledger?.mark(key, .sending)
                    try self.ledger?.prepareReplyEcho(answer, conversation: c, key: key)
                    attemptedSend = true; self.replyStates[id] = "发送中"
                    let receipt = try await ProcessRunner.run(send)
                    try self.ledger?.rememberSentMessages(receipt, conversation: c, key: key)
                    confirmed = JSONOutput.delivered(receipt)
                }
                sendSeconds += Date().timeIntervalSince(sendStart)
                terminal = confirmed ? .completed : .uncertain
                try self.ledger?.mark(key, confirmed ? .delivered : cardAccepted ? .accepted : .unknown)
                if cardAccepted, card?.interaction != nil { self.startCardExpiryMonitor(generation: generation) }
                let timing = "AI 生成 \(String(format: "%.1f", generationSeconds)) 秒 · 发送 \(String(format: "%.1f", sendSeconds)) 秒"
                if confirmed {
                    self.deliveredCount += 1
                    self.lastReplyDuration[id] = "最近回复 \(String(format: "%.1f", Date().timeIntervalSince(pending.receivedAt))) 秒"
                    self.context[id, default: []] += ["用户：\(event.content)", "助手：\(answer)"]
                    self.context[id] = Array(self.context[id, default: []].suffix(6)).map { String($0.prefix(3000)) }
                    self.log("「\(c.title)」回复已确认投递 · \(timing)")
                } else if cardAccepted {
                    self.lastReplyDuration[id] = "最近提交 \(String(format: "%.1f", Date().timeIntervalSince(pending.receivedAt))) 秒"
                    self.context[id, default: []] += ["用户：\(event.content)", "助手：\(answer)"]
                    self.context[id] = Array(self.context[id, default: []].suffix(6)).map { String($0.prefix(3000)) }
                    self.log("「\(c.title)」处理卡片已更新结果，客户端展示待确认，不会自动重发 · \(timing)", level: "提示")
                } else { self.log("「\(c.title)」投递结果待确认，不会自动重发 · \(timing)", level: "提示") }
            } catch {
                if liveProgress?.uncertain == true { updateInFlight = true; attemptedSend = true }
                terminal = attemptedSend ? .uncertain : Task.isCancelled ? nil : .failed
                var state: DeliveryRecord.State = attemptedSend ? .unknown : Task.isCancelled ? .cancelled : .failed
                // A known generation/image failure can finish the acknowledged
                // card. Never send again after an uncertain update, cancellation
                // or a change of account/configuration.
                if let reference = progressCard, !updateInFlight, !Task.isCancelled, self.storageFailure == nil,
                   self.personalRunning, self.epoch == generation, self.accountOK, self.profile?.id == c.profile,
                   self.config.conversations.first(where: { $0.id == id }) == c {
                    do {
                        let content = try AICardReply.statusContent(reference, status: "处理未完成，请查看面板日志。不会自动重试。", progress: liveProgress?.snapshot ?? .init())
                        let result = try await ProcessRunner.run(Commands.updateCard(reference, content: content, config: self.config))
                        if try AICardReply.updateAccepted(result, reference: reference) {
                            var closed = reference; closed.interaction = nil; closed.finishContent = content
                            try self.ledger?.attachCard(closed, to: key); state = .accepted; terminal = .failed
                        }
                    } catch { /* Preserve uncertainty instead of retrying. */ }
                }
                do { try self.ledger?.mark(key, state) }
                catch { self.storageFailure = "投递记录保存失败"; self.stopPersonal() }
                self.log("「\(c.title)」\(state == .unknown ? "投递未确认" : "回复已停止")：\(error.localizedDescription)", level: "提示")
            }
        }
    }

    private func changeReaction(_ reaction: ReplyReaction, remove: Bool = false, event: IMEvent, conversation: Conversation) async {
        do {
            let result = try await ProcessRunner.run(Commands.reaction(reaction, remove: remove, event: event, conversation: conversation, config: config))
            let object = try JSONOutput.object(result)
            let data = JSONOutput.payload(object)
            let nested = data["result"] as? [String: Any] ?? data
            guard nested["success"] as? Bool != false else { throw DashboardError.command("表情接口未成功") }
        } catch { log("「\(conversation.title)」\(remove ? "移除" : "添加")状态表情失败，正文回复不受影响", level: "提示") }
    }

    private func finishReactions(processing: Task<Void, Never>, terminal: ReplyReaction?, event: IMEvent, conversation: Conversation) {
        let id = UUID()
        feedbackTasks[id] = Task {
            defer { self.feedbackTasks.removeValue(forKey: id); self.finishStopping() }
            // Wait for the original add before removing it, so a slow add cannot
            // reintroduce a stale processing reaction after the final state.
            await processing.value
            await self.changeReaction(.processing, remove: true, event: event, conversation: conversation)
            if let terminal { await self.changeReaction(terminal, event: event, conversation: conversation) }
        }
    }

    func setLoginAtStartup(_ enabled: Bool) {
        guard !preview else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginAtStartup = SMAppService.mainApp.status == .enabled
            if enabled && !loginAtStartup { notice = "请在系统设置 → 通用 → 登录项中允许 DWS Dashboard" }
        } catch { report(error) }
    }

    private func loadPreview() {
        profile = ProfileSummary(id: "preview-corp:preview-user", name: "预览账号", organization: "示例工作空间")
        accountTitle = "界面预览"; accountDetail = "隔离的模拟数据 · 不会访问钉钉或启动 AI"; accountOK = false
        for (name, kind) in [("产品与研发", ConversationKind.group), ("项目日常", .group), ("协作联系人", .contact)] {
            var c = Conversation(); c.name = name; c.kind = kind; c.stableID = "preview-" + c.id.uuidString; c.profile = profile!.id
            config.conversations.append(c)
        }
        activities = [Activity(level: "信息", message: "界面预览已加载，全部监听和发送保持关闭"), Activity(level: "信息", message: "本地工作区已就绪")]
    }
    deinit {
        accountMonitor?.cancel()
        cardExpiryMonitor?.cancel()
        if instanceLock >= 0 { flock(instanceLock, LOCK_UN); Darwin.close(instanceLock) }
    }
}
