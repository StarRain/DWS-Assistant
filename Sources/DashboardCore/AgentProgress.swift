import Foundation

public struct AgentExecutionProgress: Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case dws, command, tool, search, files }
    public enum Status: String, Codable, Sendable { case running, completed, failed, cancelled, finished }
    public struct Step: Equatable, Sendable {
        public let id: String
        public let kind: Kind
        public var status: Status
    }
    public private(set) var steps: [Step] = []
    public private(set) var revision = 0
    public init() {}
    public var isEmpty: Bool { steps.isEmpty }

    fileprivate mutating func receive(_ event: Event) {
        if let index = steps.firstIndex(where: { $0.id == event.id }) {
            guard steps[index].kind == event.kind, steps[index].status == .running,
                  steps[index].status != event.status else { return }
            steps[index].status = event.status
        } else {
            guard steps.count < 128 else { return }
            steps.append(Step(id: event.id, kind: event.kind, status: event.status))
        }
        revision += 1
    }

    fileprivate struct Event: Decodable {
        let type: String
        let version: Int
        let id: String
        let kind: Kind
        let status: Status
    }

    func components(running: Bool, failed: Bool = false) -> [[String: Any]] {
        var children: [String] = [], components: [[String: Any]] = []
        for kind in Kind.allCases {
            let items = steps.filter { $0.kind == kind }
            guard !items.isEmpty else { continue }
            let id = "execution-" + kind.rawValue
            children.append(id)
            let active = items.filter { $0.status == .running }.count
            let completed = items.filter { $0.status == .completed }.count
            let errors = items.filter { $0.status == .failed }.count
            let noun: String
            let unit: String
            switch kind {
            case .dws: noun = "DWS 操作"; unit = "项"
            case .command: noun = "命令"; unit = "条"
            case .tool: noun = "工具操作"; unit = "项"
            case .search: noun = "搜索"; unit = "次"
            case .files: noun = "文件修改"; unit = "项"
            }
            let title: String
            if running && active > 0 { title = "正在执行 \(active) \(unit)\(noun) · 已完成 \(completed) \(unit)" }
            else if kind == .command { title = "已运行 \(items.count) 条命令" + (errors > 0 ? " · \(errors) 条失败" : "") }
            else if kind == .dws && completed == items.count { title = "已使用 DWS 完成 \(completed) 项操作" }
            else { title = "\(noun) · \(completed) / \(items.count) \(unit)完成" + (errors > 0 ? " · \(errors) \(unit)失败" : "") }
            var rows: [String] = []
            for (index, item) in items.enumerated() {
                let row = "execution-step-" + item.id
                rows.append(row)
                let label: String
                switch item.status {
                case .running: label = running ? "执行中" : failed ? "已停止" : "已结束，未返回步骤结果"
                case .completed: label = "已完成"
                case .failed: label = "失败"
                case .cancelled: label = "已取消"
                case .finished: label = "已结束"
                }
                components.append(["id": row, "component": "Text", "text": "\(noun) \(index + 1) · \(label)",
                                   "colorToken": "common_level2_base_color", "sizeToken": "common_footnote_text_style__font_size"])
            }
            var panel: [String: Any] = ["id": id, "component": "CollapsiblePanel", "title": title,
                "variant": "indented", "children": rows, "colorToken": "common_level2_base_color", "fallbackMarkdown": title]
            if completed == items.count { panel["icon"] = "Check_L_outlined" }
            else if running && active > 0 {
                panel["icon"] = "https://g.alicdn.com/dingding/card_a2ui/0.1.1/img/loading-circular/loading_circular_light.DlX94S3.gif"
                panel["darkIcon"] = "https://g.alicdn.com/dingding/card_a2ui/0.1.1/img/loading-circular/loading_circular_dark.D-pS11K.gif"
            }
            components.append(panel)
        }
        if steps.count == 128 {
            children.append("execution-limit")
            components.append(["id": "execution-limit", "component": "Text", "text": "最多展示前 128 项处理记录。",
                               "colorToken": "common_level2_base_color", "sizeToken": "common_footnote_text_style__font_size"])
        }
        var panel: [String: Any] = ["id": "execution-progress", "component": "CollapsiblePanel",
            "title": running ? "[AIGenerating]思考中…" : failed ? "处理已停止" : "处理过程",
            "variant": "reasoning", "children": children, "colorToken": "common_level2_base_color", "fallbackMarkdown": "执行步骤"]
        if running { panel["textEffect"] = "shimmer" }
        components.append(panel)
        return components
    }
}

/// The pipe reader may run off the main actor. Store a bounded snapshot before
/// the UI polls it, so a burst of events cannot lose completion or grow a queue.
public final class AgentProgressBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var value = AgentExecutionProgress()
    public init() {}
    public func receive(line: String) {
        guard line.utf8.count <= 1_024,
              let event = try? JSONDecoder().decode(AgentExecutionProgress.Event.self, from: Data(line.utf8)),
              event.type == "dws_agent_progress", event.version == 1,
              event.id.count == 16, event.id.allSatisfy(\.isHexDigit) else { return }
        lock.lock(); defer { lock.unlock() }
        value.receive(event)
    }
    public var snapshot: AgentExecutionProgress {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
