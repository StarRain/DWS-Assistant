// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"encoding/json"
	"errors"
)

var errAssistantEnginePermissions = errors.New("current Codex execution permissions were not applied")

func assistantPermissionMode(r AssistantAgentRequest) string {
	if r.PermissionMode != "" {
		return r.PermissionMode
	}
	if r.FullPermission {
		return "auto_review"
	}
	return "read_only"
}

func assistantValidatePermissionMode(r AssistantAgentRequest) error {
	if r.Channel != "codex" {
		if r.PermissionMode != "" || r.InteractiveApprovals {
			return errAssistantEnginePermissions
		}
		return nil
	}
	if r.InteractiveApprovals && assistantPermissionMode(r) != "ask" {
		return errAssistantEnginePermissions
	}
	switch assistantPermissionMode(r) {
	case "read_only", "ask", "auto_review", "full_access":
		return nil
	default:
		return errAssistantEnginePermissions
	}
}

func assistantApplyCodexPermissions(params map[string]any, r AssistantAgentRequest) {
	params["sandbox"], params["approvalPolicy"], params["approvalsReviewer"] = "read-only", "never", "user"
	switch assistantPermissionMode(r) {
	case "ask":
		params["sandbox"], params["approvalPolicy"] = "workspace-write", "on-request"
	case "auto_review":
		params["sandbox"], params["approvalPolicy"], params["approvalsReviewer"] = "workspace-write", "on-request", "auto_review"
	case "full_access":
		params["sandbox"] = "danger-full-access"
	}
}

func assistantCodexPermissionInstructions(r AssistantAgentRequest) string {
	common := "正规申请引擎审批不属于绕过权限。审批被拒绝或策略禁止的操作必须停止并报告原因，不换工具、会话或执行方式绕过。授权目录限定任务范围，不能自行扩大任务。"
	switch assistantPermissionMode(r) {
	case "ask":
		return "当前为请求批准模式：常规命令在 workspace-write 沙箱内运行。为完成已授权任务需要网络、钥匙串或工作区外访问时，通过原生 on-request 申请审批，宿主将展示具体操作并把用户决定返回原请求；不要生成普通确认表单代替引擎审批。" + common
	case "auto_review":
		return "当前为帮我批准模式：常规命令在 workspace-write 沙箱内运行。为完成已授权任务需要网络、钥匙串或工作区外访问时，通过原生 on-request 申请，由 auto_review 判断；申请说明应准确引用当前请求、适用规则及已有确认。" + common
	case "full_access":
		return "当前会话由用户明确选择完全访问权限，使用 danger-full-access 和 never；按实际引擎策略执行已授权任务，不将此模式视为其他任务或外发行为的授权。" + common
	default:
		return "当前为只读模式：允许读取授权项目和执行只读查询；不修改文件，不构建，不申请沙箱外权限。遇到限制说明原因，不绕过当前模式。"
	}
}

// The official managed adapter verifies permissions returned by thread/resume.
// Verify starts as well: an older app-server must not silently ignore the
// reviewer or keep a saved policy, then execute with unexpected permissions.
func assistantCodexThread(ctx context.Context, cli *codexAppServerClient, method string, params map[string]any) (string, error) {
	raw, err := assistantCodexQuery(ctx, cli, method, params)
	if err != nil {
		return "", err
	}
	if err := assistantVerifyCodexPermissions(raw, params); err != nil {
		return "", err
	}
	return codexThreadIDFromResult(raw, nil)
}

func assistantVerifyCodexPermissions(raw json.RawMessage, params map[string]any) error {
	var result struct {
		ApprovalPolicy    string `json:"approvalPolicy"`
		ApprovalsReviewer string `json:"approvalsReviewer"`
		Sandbox           struct {
			Type string `json:"type"`
		} `json:"sandbox"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return errAssistantEnginePermissions
	}
	sandbox, _ := params["sandbox"].(string)
	wantSandbox := map[string]string{"read-only": "readOnly", "workspace-write": "workspaceWrite", "danger-full-access": "dangerFullAccess"}[sandbox]
	if wantSandbox == "" || result.Sandbox.Type != wantSandbox || result.ApprovalPolicy != params["approvalPolicy"] {
		return errAssistantEnginePermissions
	}
	// The native protocol accepts this legacy spelling of auto_review.
	if result.ApprovalsReviewer == "guardian_subagent" {
		result.ApprovalsReviewer = "auto_review"
	}
	if result.ApprovalsReviewer != params["approvalsReviewer"] {
		return errAssistantEnginePermissions
	}
	return nil
}
