// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

type assistantApprovalBuffer struct{ bytes.Buffer }

func (b *assistantApprovalBuffer) Close() error { return nil }

func TestAssistantBridgeApprovalRespondsToSameRPCWithOnlyCurrentGrant(t *testing.T) {
	for _, kind := range []string{"command", "files", "permissions"} {
		for _, approved := range []bool{false, true} {
			t.Run(kind+"/"+map[bool]string{true: "accept", false: "decline"}[approved], func(t *testing.T) {
				id := 701
				method := map[string]string{"command": "item/commandExecution/requestApproval", "files": "item/fileChange/requestApproval", "permissions": "item/permissions/requestApproval"}[kind]
				params := map[string]any{"threadId": "thread", "turnId": "turn", "itemId": "item", "cwd": "/tmp/project", "reason": "fixture"}
				params["command"] = "printf fixture"
				params["permissions"] = map[string]any{"network": map[string]any{"enabled": true}}
				params["proposedExecpolicyAmendment"] = []string{"printf"}
				raw, _ := json.Marshal(params)
				item := json.RawMessage(`{"id":"item","type":"fileChange","changes":[{"path":"file.txt","diff":"+fixture"}]}`)
				buffer := &assistantApprovalBuffer{}
				client := &codexAppServerClient{stdin: buffer}
				called := 0
				ctx := WithAssistantApprovals(context.Background(), func(ctx context.Context, request AssistantApprovalRequest) (bool, error) {
					called++
					if request.Kind != kind || len(request.Token) != 64 || request.Type != "dws_engine_approval" || request.Version != 1 {
						t.Fatalf("bad event: %+v", request)
					}
					if request.ExpiresAt <= time.Now().UnixMilli() || request.ExpiresAt > time.Now().Add(91*time.Second).UnixMilli() {
						t.Fatal("invalid deadline")
					}
					if kind == "files" && !strings.Contains(request.Details, "+fixture") {
						t.Fatal("file approval omitted concrete changes")
					}
					if strings.Contains(request.Details, "proposedExecpolicyAmendment") {
						t.Fatal("persistent amendment offered")
					}
					return approved, nil
				})
				if err := assistantHandleApproval(ctx, client, codexRPCMessage{ID: &id, Method: method, Params: raw}, "thread", "turn", map[string]json.RawMessage{"item": item}); err != nil {
					t.Fatal(err)
				}
				var reply struct {
					ID     int
					Result map[string]json.RawMessage
				}
				if json.Unmarshal(buffer.Bytes(), &reply) != nil || reply.ID != id || called != 1 {
					t.Fatal("lost RPC binding")
				}
				if kind == "permissions" {
					if string(reply.Result["scope"]) != `"turn"` {
						t.Fatal("grant escaped current turn")
					}
					if approved != strings.Contains(string(reply.Result["permissions"]), `"enabled":true`) {
						t.Fatal("wrong permission decision")
					}
				} else {
					want := `"decline"`
					if approved {
						want = `"accept"`
					}
					if string(reply.Result["decision"]) != want || len(reply.Result) != 1 {
						t.Fatal("approval expanded beyond current action")
					}
				}
			})
		}
	}
}

func TestAssistantBridgeApprovalRejectsUnboundUnsupportedOrExpiredRequests(t *testing.T) {
	cases := []struct {
		name, method, params, thread, turn string
		handler                            bool
		cancelled                          bool
	}{
		{"wrong thread", "item/commandExecution/requestApproval", `{"threadId":"other","turnId":"turn","itemId":"item","command":"printf x"}`, "thread", "turn", true, false},
		{"wrong turn", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"other","itemId":"item","command":"printf x"}`, "thread", "turn", true, false},
		{"no active turn", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item","command":"printf x"}`, "thread", "", true, false},
		{"missing item", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"turn","command":"printf x"}`, "thread", "turn", true, false},
		{"hidden diff", "item/fileChange/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item"}`, "thread", "turn", true, false},
		{"empty command", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item"}`, "thread", "turn", true, false},
		{"invalid command", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item","command":true}`, "thread", "turn", true, false},
		{"invalid permissions", "item/permissions/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item","permissions":"all"}`, "thread", "turn", true, false},
		{"unknown request", "account/login/requestApproval", `{}`, "thread", "turn", true, false},
		{"no handler", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item","command":"printf x"}`, "thread", "turn", false, false},
		{"cancelled", "item/commandExecution/requestApproval", `{"threadId":"thread","turnId":"turn","itemId":"item","command":"printf x"}`, "thread", "turn", true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			calls := 0
			if tc.handler {
				ctx = WithAssistantApprovals(ctx, func(context.Context, AssistantApprovalRequest) (bool, error) { calls++; return true, nil })
			}
			if tc.cancelled {
				cancel()
			}
			id := 42
			buffer := &assistantApprovalBuffer{}
			err := assistantHandleApproval(ctx, &codexAppServerClient{stdin: buffer}, codexRPCMessage{ID: &id, Method: tc.method, Params: json.RawMessage(tc.params)}, tc.thread, tc.turn, nil)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(buffer.String(), `"accept"`) || !strings.Contains(buffer.String(), `"id":42`) {
				t.Fatal("invalid request approved")
			}
			if !tc.cancelled && calls != 0 {
				t.Fatal("invalid request presented as approvable")
			}
		})
	}
	request := AssistantApprovalRequest{Token: "original", ExpiresAt: time.Now().Add(time.Second).UnixMilli()}
	response := AssistantApprovalResponse{Type: "dws_engine_approval_response", Version: 1, Token: "original", Decision: "accept"}
	if !response.Accepts(request) {
		t.Fatal("valid response refused")
	}
	for _, changed := range []AssistantApprovalResponse{
		{Type: response.Type, Version: 1, Token: "stale", Decision: "accept"},
		{Type: response.Type, Version: 1, Token: request.Token, Decision: "acceptForSession"},
		{Type: response.Type, Version: 2, Token: request.Token, Decision: "accept"},
		{Type: "dws_interaction", Version: 1, Token: request.Token, Decision: "accept"},
	} {
		if changed.Accepts(request) {
			t.Fatal("stale or expanded decision accepted")
		}
	}
	request.ExpiresAt = time.Now().Add(-time.Second).UnixMilli()
	if response.Accepts(request) {
		t.Fatal("expired approval accepted")
	}
}

func TestAssistantBridgeLateOrFailedApprovalCannotGrant(t *testing.T) {
	for _, timeout := range []bool{false, true} {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
		defer cancel()
		ctx = WithAssistantApprovals(ctx, func(waiting context.Context, request AssistantApprovalRequest) (bool, error) {
			if request.ExpiresAt > time.Now().Add(time.Second).UnixMilli() {
				t.Fatal("approval exceeds task deadline")
			}
			if timeout {
				<-waiting.Done()
				return true, nil
			}
			return true, errors.New("transport failed")
		})
		id := 9
		buffer := &assistantApprovalBuffer{}
		raw := json.RawMessage(`{"threadId":"thread","turnId":"turn","itemId":"item","command":"printf x"}`)
		if err := assistantHandleApproval(ctx, &codexAppServerClient{stdin: buffer}, codexRPCMessage{ID: &id, Method: "item/commandExecution/requestApproval", Params: raw}, "thread", "turn", nil); err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(buffer.String(), `"decision":"decline"`) {
			t.Fatal("late or failed approval granted")
		}
	}
}

func TestAssistantBridgeApprovalRoundTripKeepsNewAndResumedTurn(t *testing.T) {
	for _, bound := range []bool{false, true} {
		for _, approved := range []bool{false, true} {
			clearChannelEnv(t)
			dir, state := t.TempDir(), t.TempDir()
			log := assistantCodexLifecycleStub(t, dir, "native_approval")
			t.Setenv("DWS_CONFIG_DIR", state)
			req := AssistantAgentRequest{Channel: "codex", CodexHome: t.TempDir(), ConversationID: "c", ScopeID: "s", Text: "fixture", WorkDir: dir, StateDir: state, TimeoutSeconds: 10, PermissionMode: "ask", InteractiveApprovals: true}
			if bound {
				newCodexThreadSessions(codexThreadStorePath(req.ScopeID)).setThreadID(req.ConversationID, "thr_existing")
			}
			calls := 0
			ctx := WithAssistantApprovals(context.Background(), func(_ context.Context, request AssistantApprovalRequest) (bool, error) {
				calls++
				if !strings.Contains(request.Details, "printf fixture") {
					t.Fatal("concrete command missing")
				}
				return approved, nil
			})
			result, err := RunAssistantAgentWithStatus(ctx, req)
			want := "decline"
			if approved {
				want = "accept"
			}
			if err != nil || result.Answer != want || calls != 1 {
				t.Fatalf("round trip failed: %+v %v calls=%d", result, err, calls)
			}
			data, _ := os.ReadFile(log)
			if strings.Count(string(data), `"method":"turn/start"`) != 1 || strings.Count(string(data), `"id":900`) != 1 {
				t.Fatal("approval replayed or detached task")
			}
			if bound && (strings.Contains(string(data), `"method":"thread/start"`) || newCodexThreadSessions(codexThreadStorePath(req.ScopeID)).threadID(req.ConversationID) != "thr_existing") {
				t.Fatal("approval restarted existing conversation")
			}
		}
	}
}

func TestAssistantBridgeAskWithoutLiveChannelFailsBeforeStartingEngine(t *testing.T) {
	req := AssistantAgentRequest{Channel: "codex", PermissionMode: "ask", InteractiveApprovals: true}
	if _, err := RunAssistantAgentWithStatus(context.Background(), req); !errors.Is(err, errAssistantApprovalUnavailable) {
		t.Fatalf("missing handler not rejected: %v", err)
	}
	req.InteractiveApprovals = false
	ctx := WithAssistantApprovals(context.Background(), func(context.Context, AssistantApprovalRequest) (bool, error) {
		t.Fatal("unexpected approval")
		return true, nil
	})
	if _, err := RunAssistantAgentWithStatus(ctx, req); !errors.Is(err, errAssistantApprovalUnavailable) {
		t.Fatalf("closed channel not rejected: %v", err)
	}
}
