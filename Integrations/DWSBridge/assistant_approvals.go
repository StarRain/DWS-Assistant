// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

var errAssistantApprovalUnavailable = errors.New("native approval channel unavailable")

// This separate channel carries real app-server requests, never AI-produced
// forms. The opaque token binds one host decision to one pending RPC callback.
type AssistantApprovalRequest struct {
	Type      string `json:"type"`
	Version   int    `json:"version"`
	Token     string `json:"token"`
	Kind      string `json:"kind"`
	Details   string `json:"details"`
	ExpiresAt int64  `json:"expires_at"`
}

type AssistantApprovalResponse struct {
	Type     string `json:"type"`
	Version  int    `json:"version"`
	Token    string `json:"token"`
	Decision string `json:"decision"`
}

func (r AssistantApprovalResponse) Accepts(request AssistantApprovalRequest) bool {
	return r.Type == "dws_engine_approval_response" && r.Version == 1 &&
		r.Token == request.Token && r.Decision == "accept" && time.Now().UnixMilli() < request.ExpiresAt
}

type assistantApprovalKey struct{}
type AssistantApprovalHandler func(context.Context, AssistantApprovalRequest) (bool, error)

func WithAssistantApprovals(ctx context.Context, handler AssistantApprovalHandler) context.Context {
	return context.WithValue(ctx, assistantApprovalKey{}, handler)
}

func assistantApprovalHandler(ctx context.Context) AssistantApprovalHandler {
	handler, _ := ctx.Value(assistantApprovalKey{}).(AssistantApprovalHandler)
	return handler
}

func assistantHandleApproval(ctx context.Context, c *codexAppServerClient, msg codexRPCMessage, threadID, turnID string, items map[string]json.RawMessage) error {
	handler := assistantApprovalHandler(ctx)
	if handler == nil {
		c.rejectServerRequest(*msg.ID, msg.Method)
		return nil
	}
	kind := ""
	switch msg.Method {
	case "item/commandExecution/requestApproval":
		kind = "command"
	case "item/fileChange/requestApproval":
		kind = "files"
	case "item/permissions/requestApproval":
		kind = "permissions"
	default:
		c.rejectServerRequest(*msg.ID, msg.Method)
		return nil
	}
	var params map[string]json.RawMessage
	var identity struct {
		ThreadID string `json:"threadId"`
		TurnID   string `json:"turnId"`
		ItemID   string `json:"itemId"`
	}
	valid := len(msg.Params) <= 64*1024 && json.Unmarshal(msg.Params, &params) == nil && json.Unmarshal(msg.Params, &identity) == nil &&
		threadID != "" && turnID != "" && identity.ThreadID == threadID && identity.TurnID == turnID && identity.ItemID != ""
	details := map[string]json.RawMessage{}
	// Preserve the exact action and requested access. Never apply proposed
	// persistent command/network amendments or grant a session-wide approval.
	for _, key := range []string{"command", "cwd", "environmentId", "reason", "kind", "networkApprovalContext", "additionalPermissions", "permissions", "grantRoot"} {
		if value, ok := params[key]; ok && string(value) != "null" {
			details[key] = value
		}
	}
	if kind == "files" {
		if item, ok := items[identity.ItemID]; ok {
			details["fileChange"] = item
		} else {
			valid = false
		}
	}
	if kind == "command" {
		var command string
		var network map[string]json.RawMessage
		hasCommand := json.Unmarshal(details["command"], &command) == nil && strings.TrimSpace(command) != ""
		hasNetwork := json.Unmarshal(details["networkApprovalContext"], &network) == nil && len(network) > 0
		valid = valid && (hasCommand || hasNetwork)
	}
	if kind == "permissions" {
		var permissions map[string]json.RawMessage
		valid = valid && json.Unmarshal(details["permissions"], &permissions) == nil && len(permissions) > 0
	}
	data, err := json.MarshalIndent(details, "", "  ")
	if err != nil || len(data) > 48*1024 {
		valid = false
	}
	accepted := false
	if valid && ctx.Err() == nil {
		random := make([]byte, 32)
		if _, err := rand.Read(random); err != nil {
			return err
		}
		waiting, cancel := context.WithTimeout(ctx, 90*time.Second)
		deadline, _ := waiting.Deadline()
		request := AssistantApprovalRequest{Type: "dws_engine_approval", Version: 1, Token: hex.EncodeToString(random), Kind: kind, Details: string(data), ExpiresAt: deadline.UnixMilli()}
		accepted, err = handler(waiting, request)
		accepted = accepted && err == nil && waiting.Err() == nil
		cancel()
	}
	result := map[string]any{"decision": "decline"}
	if accepted {
		result["decision"] = "accept"
	}
	if kind == "permissions" {
		result = map[string]any{"permissions": map[string]any{}, "scope": "turn"}
		if accepted {
			result["permissions"] = params["permissions"]
		}
	}
	return c.send(map[string]any{"id": *msg.ID, "result": result})
}
