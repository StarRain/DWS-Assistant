// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
)

func TestAssistantBridgeVerifiesNativeCodexPermissions(t *testing.T) {
	for _, tc := range []struct {
		name, sandbox, approval, reviewer string
		full, valid                       bool
	}{
		{"restricted", "readOnly", "never", "user", false, true},
		{"automatic", "workspaceWrite", "on-request", "auto_review", true, true},
		{"legacy reviewer spelling", "workspaceWrite", "on-request", "guardian_subagent", true, true},
		{"ignored reviewer", "workspaceWrite", "on-request", "", true, false},
		{"saved never policy", "workspaceWrite", "never", "auto_review", true, false},
		{"saved human reviewer", "workspaceWrite", "on-request", "user", true, false},
		{"saved readonly sandbox", "readOnly", "on-request", "auto_review", true, false},
		{"unrestricted sandbox", "dangerFullAccess", "on-request", "auto_review", true, false},
		{"downgrade ignored", "workspaceWrite", "never", "user", false, false},
		{"reviewer not cleared", "readOnly", "never", "auto_review", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			params := map[string]any{"sandbox": "read-only", "approvalPolicy": "never", "approvalsReviewer": "user"}
			if tc.full {
				params["sandbox"], params["approvalPolicy"], params["approvalsReviewer"] = "workspace-write", "on-request", "auto_review"
			}
			raw, _ := json.Marshal(map[string]any{"sandbox": map[string]string{"type": tc.sandbox}, "approvalPolicy": tc.approval, "approvalsReviewer": tc.reviewer})
			err := assistantVerifyCodexPermissions(raw, params)
			if (err == nil) != tc.valid || (err != nil && !errors.Is(err, errAssistantEnginePermissions)) {
				t.Fatalf("valid=%v error=%v", tc.valid, err)
			}
		})
	}
	for _, raw := range []string{`{}`, `{"sandbox":{"type":"readOnly"},"approvalPolicy":{}}`, `invalid`} {
		if err := assistantVerifyCodexPermissions(json.RawMessage(raw), nil); !errors.Is(err, errAssistantEnginePermissions) {
			t.Fatalf("accepted malformed response: %v", err)
		}
	}
}

func TestAssistantBridgeStopsBeforeTurnWhenCodexIgnoresPermissions(t *testing.T) {
	for _, bound := range []bool{false, true} {
		name := "start"
		if bound {
			name = "resume"
		}
		t.Run(name, func(t *testing.T) {
			clearChannelEnv(t)
			dir, state := t.TempDir(), t.TempDir()
			log := assistantCodexLifecycleStub(t, dir, "stale_permissions")
			t.Setenv("DWS_CONFIG_DIR", state)
			req := AssistantAgentRequest{Channel: "codex", CodexHome: t.TempDir(), ConversationID: "c", ScopeID: "s", Text: "check login", WorkDir: dir, StateDir: state, TimeoutSeconds: 10, FullPermission: true}
			path := codexThreadStorePath(req.ScopeID)
			seed := ""
			if bound {
				seed = "thr_existing"
				newCodexThreadSessions(path).setThreadID(req.ConversationID, seed)
			}
			_, err := RunAssistantAgentWithStatus(context.Background(), req)
			if !errors.Is(err, errAssistantEnginePermissions) || AssistantAgentFailureReason(err) != "engine_permissions_failed" {
				t.Fatalf("unexpected failure: %v", err)
			}
			if newCodexThreadSessions(path).threadID(req.ConversationID) != seed {
				t.Fatal("permission failure changed the session binding")
			}
			data, _ := os.ReadFile(log)
			if strings.Contains(string(data), `"method":"turn/start"`) || (bound && strings.Contains(string(data), `"method":"thread/start"`)) {
				t.Fatal("permission failure executed or replayed a task")
			}
		})
	}
}

func TestAssistantBridgeAllNativeModesApplyBeforeNewAndResumedTurns(t *testing.T) {
	for _, tc := range []struct{ mode, sandbox, policy, reviewer string }{
		{"read_only", "read-only", "never", "user"},
		{"ask", "workspace-write", "on-request", "user"},
		{"auto_review", "workspace-write", "on-request", "auto_review"},
		{"full_access", "danger-full-access", "never", "user"},
	} {
		for _, bound := range []bool{false, true} {
			clearChannelEnv(t)
			dir, state := t.TempDir(), t.TempDir()
			log := assistantCodexLifecycleStub(t, dir, "")
			t.Setenv("DWS_CONFIG_DIR", state)
			req := AssistantAgentRequest{Channel: "codex", CodexHome: t.TempDir(), ConversationID: "c", ScopeID: "s", Text: "fixture", WorkDir: dir, StateDir: state, TimeoutSeconds: 10, PermissionMode: tc.mode, InteractiveApprovals: tc.mode == "ask"}
			if bound {
				newCodexThreadSessions(codexThreadStorePath(req.ScopeID)).setThreadID(req.ConversationID, "thr_existing")
			}
			ctx := WithAssistantApprovals(context.Background(), func(context.Context, AssistantApprovalRequest) (bool, error) {
				t.Fatal("unexpected native request")
				return false, nil
			})
			if _, err := RunAssistantAgentWithStatus(ctx, req); err != nil {
				t.Fatalf("%s: %v", tc.mode, err)
			}
			data, _ := os.ReadFile(log)
			applied := 0
			for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
				var call struct {
					Method string
					Params map[string]any
				}
				if err := json.Unmarshal([]byte(line), &call); err != nil {
					t.Fatal(err)
				}
				if call.Method != "thread/start" && call.Method != "thread/resume" {
					continue
				}
				applied++
				if (call.Method == "thread/resume") != bound {
					t.Fatal("changed session lifecycle")
				}
				if call.Params["sandbox"] != tc.sandbox || call.Params["approvalPolicy"] != tc.policy || call.Params["approvalsReviewer"] != tc.reviewer {
					t.Fatalf("%s applied wrong permissions: %+v", tc.mode, call.Params)
				}
			}
			if applied != 1 || strings.Count(string(data), `"method":"turn/start"`) != 1 {
				t.Fatal("task executed before a single verified configuration")
			}
		}
	}
	if assistantPermissionMode(AssistantAgentRequest{FullPermission: true}) != "auto_review" {
		t.Fatal("legacy full was upgraded")
	}
	for _, req := range []AssistantAgentRequest{
		{Channel: "codex", PermissionMode: "unknown"},
		{Channel: "codex", PermissionMode: "auto_review", InteractiveApprovals: true},
		{Channel: "qoder", PermissionMode: "ask"},
	} {
		if assistantValidatePermissionMode(req) == nil {
			t.Fatal("unsupported mode accepted")
		}
	}
}
