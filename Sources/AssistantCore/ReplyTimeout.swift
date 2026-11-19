import Foundation

/// Identifies the deadline that actually fired. A conversation limit must not
/// be inferred from an arbitrary engine error or an uncertain delivery result.
public enum ReplyTimeout: LocalizedError, Equatable {
    case executionLimit(seconds: Int)
    case engineReported(engine: Engine)
    case resultWait(seconds: Int)
    case messageDelivery(seconds: Int)
    case cardUpdate(seconds: Int)
    case imageRead(seconds: Int)
    case cardWaiting(seconds: Int?)

    public var message: String {
        switch self {
        case .executionLimit(let seconds):
            return "执行超时：已达到此会话设置的 \(seconds) 秒执行时限，DWS助手已结束本次等待。计时包含 AI 思考、工具调用及等待脚本返回。可在「会话配置 → AI 回复设置 → 单次执行超时」调整。不会自动重试；已启动脚本的结果需另行核对。"
        case .engineReported(let engine):
            return "引擎调用超时（\(engine.title)）：未取得最终结果，未确认由会话执行时限触发。请检查引擎状态，不会自动重试。"
        case .resultWait(let seconds):
            return "执行结果读取超时：等待本地引擎进程返回结果已超过 \(seconds) 秒，仍未收到最终结果。已请求进程退出，不会自动重试；已启动任务的结果需另行核对。"
        case .messageDelivery(let seconds):
            return "消息发送超时：在 \(seconds) 秒内未收到钉钉的发送确认，消息可能已送达。请在原会话核对，不会自动重发。"
        case .cardUpdate(let seconds):
            return "卡片更新超时：在 \(seconds) 秒内未收到钉钉的更新确认，卡片状态待核对。已停止后续处理，不会自动重试。"
        case .imageRead(let seconds):
            return "图片读取超时：在 \(seconds) 秒内未完成图片信息获取或下载，本次 AI 处理尚未开始。请稍后重新发起。"
        case .cardWaiting(let seconds):
            if let seconds {
                return "卡片等待超时：未在此卡片设置的 \(seconds) 秒内收到有效提交，卡片已失效，未启动后续任务。请发送新消息重新发起。"
            }
            return "卡片等待超时：操作期限内未收到有效提交，卡片已失效，未启动后续任务。请发送新消息重新发起。"
        }
    }

    public var errorDescription: String? { message }
    public func logMessage(conversation: String) -> String { "「\(conversation)」\(message)" }

    public static func waiting(for interaction: CardInteraction?) -> ReplyTimeout {
        // Older cards have no creation time. Do not guess their original limit
        // from today's conversation settings.
        let seconds = interaction.flatMap { value in
            value.createdAt.map { Int(value.expiresAt.timeIntervalSince($0).rounded()) }
        }
        return .cardWaiting(seconds: seconds.flatMap { $0 > 0 ? $0 : nil })
    }
}
