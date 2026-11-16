import Foundation

/// A read-only local snapshot. It does not prove network access or every
/// organization permission, and an unreadable snapshot is not a logout.
public struct DWSAccountCheck {
    public enum State { case unchecked, unavailable, signedOut, authorized, indeterminate }
    public let state: State
    public let profile: ProfileSummary?
    public let title: String
    public let detail: String

    public init(_ result: CommandResult) throws {
        let data = JSONOutput.payload(try JSONOutput.object(result))
        guard data["success"] as? Bool != false, let authenticated = data["authenticated"] as? Bool else {
            throw DashboardError.command("DWS 未返回可识别的登录状态，请检查安装版本后重试")
        }
        let reason = JSONOutput.string(data, "reason")
        if !reason.isEmpty {
            state = .indeterminate; profile = nil; title = "暂时无法确认登录状态"
            detail = Redaction.clean(JSONOutput.string(data, "message").nonempty ?? "无法读取本机授权信息，请检查 DWS 登录状态后重新检测。")
        } else if authenticated, let current = JSONOutput.currentProfile(data) {
            try Validation.profile(current.id)
            state = .authorized; profile = current; title = "DWS 已授权"
            detail = data["token_valid"] as? Bool == false && data["refresh_token_valid"] as? Bool == true
                ? "已读取当前账号；DWS 会在请求时自动续期。"
                : "已读取当前账号的本机授权信息。"
        } else if authenticated {
            state = .indeterminate; profile = nil; title = "账号信息不完整"
            detail = "已发现授权，但未取得当前账号信息，请重新检测。"
        } else {
            state = .signedOut; profile = nil; title = "尚未登录钉钉"
            detail = "通过钉钉官方授权登录，完成后自动检测结果。"
        }
    }
}
