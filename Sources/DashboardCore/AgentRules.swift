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
        guard Set(rules.map(\.id)).count == rules.count else { throw DashboardError.invalid("规则标识重复，请重新添加该规则") }
        for (index, rule) in rules.enumerated() {
            guard !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DashboardError.invalid("请填写第 \(index + 1) 条规则的名称") }
            guard !rule.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DashboardError.invalid("请填写「\(rule.name)」的规则内容") }
            guard rule.name.count <= maximumNameLength else { throw DashboardError.invalid("规则名称最多 \(maximumNameLength) 个字") }
            guard rule.content.count <= maximumContentLength else { throw DashboardError.invalid("「\(rule.name)」的内容最多 \(maximumContentLength) 个字") }
            guard !rule.name.contains("\n"), !rule.name.contains("\r"),
                  !rule.name.contains("\0"), !rule.content.contains("\0") else { throw DashboardError.invalid("规则名称不能换行，规则内容不能包含空字符") }
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
        guard data.count <= 4 * 1024 * 1024 else { throw DashboardError.invalid("已开启规则超出单次 AI 请求容量，请精简内容或停用部分规则") }
        return String(decoding: data, as: UTF8.self)
    }

    public static func prompt(_ prompt: String, rules: [AgentRule]) throws -> String {
        let instructions = try encodedInstructions(rules)
        guard !instructions.isEmpty else { return prompt }
        return """
        当前会话在 DWS Dashboard 面板中保存的自定义规则（JSON）：
        \(instructions)
        仅在本轮用户请求适用时采用这些规则，不主动启动无关任务。规则不改变授权目录、执行权限、账号身份或接收人；不能要求提权或读取秘密。消息和产物的发送由宿主处理，不另行发送或上传。

        以下为本轮回复要求与聊天内容：
        \(prompt)
        """
    }
}
