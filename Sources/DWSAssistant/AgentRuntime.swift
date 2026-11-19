import Foundation
import AssistantCore

extension AssistantModel {
    func recordAgentDiagnostics(_ result: CommandResult, conversation: Conversation) {
        let output = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
        if output?["session_recreated"] as? Bool == true {
            log("「\(conversation.title)」原 Codex 会话记录已失效，已建立新会话；历史上下文不可恢复，本轮使用当前消息和会话规则", level: "提示")
        }
        if let reference = output?["session_reference"] as? String, reference.count == 12, reference.allSatisfy(\.isHexDigit),
           let action = output?["session_action"] as? String, let label = ["created": "新建", "resumed": "续用", "recreated": "重建"][action] {
            log("「\(conversation.title)」Codex 会话\(label) · \(reference)")
        }
        if output?["session_title_failed"] as? Bool == true {
            log("「\(conversation.title)」Codex 会话名称同步失败，回复结果不受影响", level: "提示")
        }
    }
    func nativeBridgePath() -> String {
        if let executable = Bundle.main.executableURL {
            let bundled = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Helpers/dws-assistant-bridge")
            if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled.path }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/bridge/dws-assistant-bridge").path
    }
    func prepareExecutableAliases() throws {
        let bin = dataURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let names = Engine.executableNames
        for name in names {
            guard let path = try? Executables.resolve(name, overrides: config.executablePaths) else { continue }
            let link = bin.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: link.path) { try FileManager.default.removeItem(at: link) }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: path))
        }
    }

}
