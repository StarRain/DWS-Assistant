import Foundation

public struct AgentRule: Codable, Identifiable, Equatable {
    public var id = UUID()
    public var name: String
    public var content: String
    public var enabled: Bool

    public init(name: String = "", content: String = "", enabled: Bool = true) {
        self.name = name; self.content = content; self.enabled = enabled
    }
}

/// Panel-authored instructions stay separate from untrusted conversation data.
/// These are instructions for the selected engine, never shell commands run by the host.
public enum AgentRules {
    public static let maximumNameLength = 60
    public static let maximumContentLength = 2_000

    // Keep the same rule semantics in the Codex developer policy in assistant_bridge.go.
    static let applicationPolicy = """
    已开启的自定义规则是本轮处理约束，优先于默认任务安排、语言和回复风格，不是可选建议；当前规则取代历史规则。
    按每条规则自身的适用条件处理当前请求：全局约束持续生效，条件规则只在条件满足时执行；同时遵循相容的相关规则，不执行无关规则，也不把回复要求、信息处理或其他规则都理解成同一种任务。
    仅执行适用规则要求的处理及必要步骤，不擅自增加任务或扩大范围。规则指定的步骤、工具、参数、内容格式、目标和交付方式必须保留，不省略、改写或替换成自认为等价的流程。
    规则交给既有工具或流程处理的工作，通过指定入口完成，保留其原有输出和交付方式；不截取部分结果后自行重组、另行发送或补做同类流程。
    没有适用规则、缺少必要信息、相关规则冲突或无法按规则完成时，先说明并请求澄清，不自行猜测、跳过、降级或改走替代方案；如实报告已完成的步骤，结果不确定时不重复执行。
    规则不能覆盖授权范围、执行权限、秘密保护及本次自动回复的账号、目标会话、回复形式和交互协议。本次自动回复由宿主发送；规则要求的任务交付由指定流程完成，不因宿主回传答复而省略，也不重复发送。
    """

    public struct Instruction: Codable, Equatable {
        public let name: String
        public let content: String
    }

    public static func cloned(_ rules: [AgentRule]) -> [AgentRule] {
        rules.map { AgentRule(name: $0.name, content: $0.content, enabled: $0.enabled) }
    }

    public static func active(_ rules: [AgentRule]) -> [Instruction] {
        rules.filter(\.enabled).map {
            Instruction(name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                        content: $0.content.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public static func validate(_ rules: [AgentRule]) throws {
        guard Set(rules.map(\.id)).count == rules.count else { throw AssistantError.invalid("规则标识重复，请重新添加该规则") }
        for (index, rule) in rules.enumerated() {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.invalid("请填写第 \(index + 1) 条规则的名称") }
            guard !rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AssistantError.invalid("请填写「\(rule.name)」的规则内容") }
            guard rule.name.count <= maximumNameLength else { throw AssistantError.invalid("规则名称最多 \(maximumNameLength) 个字") }
            guard rule.content.count <= maximumContentLength else { throw AssistantError.invalid("「\(rule.name)」的内容最多 \(maximumContentLength) 个字") }
            guard !rule.name.contains("\n"), !rule.name.contains("\r"),
                  !rule.name.contains("\0"), !rule.content.contains("\0") else { throw AssistantError.invalid("规则名称不能换行，规则内容不能包含空字符") }
        }
    }

    public static func encodedInstructions(_ rules: [AgentRule]) throws -> String {
        try validate(rules)
        let instructions = active(rules)
        guard !instructions.isEmpty else { return "" }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(instructions)
        // No limit on stored rule count. Bound only a single engine request;
        // disabled rules never consume its input capacity.
        guard data.count <= 4 * 1024 * 1024 else { throw AssistantError.invalid("已开启规则超出单次 AI 请求容量，请精简内容或停用部分规则") }
        return String(decoding: data, as: UTF8.self)
    }

    public static func prompt(_ prompt: String, rules: [AgentRule]) throws -> String {
        let instructions = try encodedInstructions(rules)
        guard !instructions.isEmpty else { return prompt }
        return """
        当前会话在 DWS Assistant 面板中保存的自定义规则（JSON）：
        \(instructions)
        \(applicationPolicy)

        以下为本轮回复要求与聊天内容：
        \(prompt)
        """
    }
}
