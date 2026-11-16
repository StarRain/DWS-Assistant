import XCTest
import DashboardCore
@testable import DWSAssistant

final class LocalizationTests: XCTestCase {
    private let english = UILocalizer(locale: Locale(identifier: "en"))
    private let chinese = UILocalizer(locale: Locale(identifier: "zh-Hans"))

    func testChineseDefaultAndLegacyConfiguration() throws {
        XCTAssertEqual(AppLanguage.allCases, [.simplifiedChinese, .english])
        XCTAssertEqual(DashboardConfig().language, .simplifiedChinese)
        XCTAssertEqual(AppLanguage.english.locale.identifier, "en")
        XCTAssertEqual(AppLanguage.simplifiedChinese.locale.identifier, "zh-Hans")
        let old = Data(#"{"schemaVersion":1,"conversations":[],"executablePaths":{}}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DashboardConfig.self, from: old).language, .simplifiedChinese)
        let automatic = Data(#"{"schemaVersion":1,"conversations":[],"executablePaths":{},"language":"system"}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(DashboardConfig.self, from: automatic).language, .simplifiedChinese)
        for language in AppLanguage.allCases {
            var config = DashboardConfig(); config.language = language
            XCTAssertEqual(try JSONDecoder().decode(DashboardConfig.self, from: JSONEncoder().encode(config)), config)
        }
    }

    func testInterpolationDoesNotTranslateOrReinterpretUserContent() {
        let name = "群聊 {1} %s \\ 脚本.sh"
        let message: UIMessage = "删除「\(name)」？"
        XCTAssertEqual(english.text(message), "Delete “\(name)”?")
        XCTAssertEqual(chinese.text(message), "删除「\(name)」？")
        XCTAssertEqual(english.label("new-engine-id"), "new-engine-id")
    }

    func testExistingLogPresentationPreservesNamesAndOriginalText() {
        let original = "「群聊 {0}」回复已确认投递 · AI 生成 1.2 秒 · 发送 0.5 秒"
        XCTAssertEqual(english.diagnostic(original), "“群聊 {0}”: delivery confirmed · AI generation 1.2 sec · sending 0.5 sec")
        XCTAssertEqual(chinese.diagnostic(original), original)
        let cliOutput = "Some external output: 事件通道已就绪"
        XCTAssertEqual(english.diagnostic(cliOutput), cliOutput)
        XCTAssertEqual(english.diagnostic("请填写「用户规则」的规则内容"), "Enter content for “用户规则”")
    }

    func testCatalogPlaceholdersAndAllOptionLabelsAreTranslated() throws {
        let placeholders = try NSRegularExpression(pattern: #"\{\d+\}"#)
        func tokens(_ text: String) -> [String] {
            placeholders.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { (text as NSString).substring(with: $0.range) }.sorted()
        }
        XCTAssertGreaterThan(UILocalizer.english.count, 300)
        for (key, value) in UILocalizer.english {
            XCTAssertEqual(tokens(key), tokens(value), key)
            XCTAssertFalse(value.isEmpty, key)
            XCTAssertNil(value.range(of: #"[\u4E00-\u9FFF]"#, options: .regularExpression), key)
        }
        let labels = ReplyTrigger.allCases.flatMap { [$0.title, $0.detail] }
            + ReplyFormat.allCases.map(\.title) + ExecutionPermission.allCases.map(\.title)
            + AppAppearance.allCases.map(\.title)
        for label in labels where label != "Markdown" {
            XCTAssertNotEqual(english.label(label), label, label)
            XCTAssertEqual(chinese.label(label), label)
        }
    }

    @MainActor
    func testLanguageSwitchPersistsWithoutChangingChatSettingsOrRuntime() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("language-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = DashboardModel(directory: directory, authDirectories: [])
        var chat = Conversation(); chat.profile = "corp:user"; chat.stableID = "cid-language"; chat.name = "群聊"
        chat.agent.rules = [AgentRule(name: "保持中文", content: "回答使用中文")]
        var config = model.config; config.conversations = [chat]; config.setupCompleted = true
        try model.persist(config)
        model.personalRunning = true
        model.replyStates[chat.id] = "AI 生成中"
        model.listenerStates[chat.id.uuidString] = "监听中"
        model.setLanguage(.english)
        XCTAssertEqual(model.config.language, .english)
        XCTAssertEqual(model.config.conversations, [chat])
        XCTAssertTrue(model.personalRunning)
        XCTAssertEqual(model.replyStates[chat.id], "AI 生成中")
        XCTAssertEqual(model.listenerStates[chat.id.uuidString], "监听中")
        XCTAssertEqual(try model.store?.load("config.json", as: DashboardConfig.self)?.language, .english)
        model.setLanguage(.simplifiedChinese)
        XCTAssertEqual(model.config.conversations, [chat])
        XCTAssertTrue(model.personalRunning)
    }
}
