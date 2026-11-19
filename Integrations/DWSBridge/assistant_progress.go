// Copyright 2026 DWS Assistant contributors
// Portions derived from DWS CLI, Copyright 2026 Alibaba Group.
// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"path/filepath"
	"strings"
)

// Only allowlisted lifecycle metadata crosses into the card renderer.
// Never forward reasoning, commands, arguments, results, or raw identifiers.
type AssistantAgentProgress struct {
	Type    string `json:"type"`
	Version int    `json:"version"`
	ID      string `json:"id"`
	Kind    string `json:"kind"`
	Status  string `json:"status"`
}

type assistantProgressKey struct{}

func RunAssistantAgentWithProgress(ctx context.Context, r AssistantAgentRequest, emit func(AssistantAgentProgress)) (AssistantAgentResult, error) {
	if emit != nil {
		ctx = context.WithValue(ctx, assistantProgressKey{}, emit)
	}
	return RunAssistantAgentWithStatus(ctx, r)
}

func assistantProgressSink(ctx context.Context) func(AssistantAgentProgress) {
	emit, _ := ctx.Value(assistantProgressKey{}).(func(AssistantAgentProgress))
	return emit
}

type assistantCodexProgress struct {
	emit func(AssistantAgentProgress)
	seen map[string]AssistantAgentProgress
}

func (p *assistantCodexProgress) handle(method string, raw json.RawMessage, threadID, turnID string) {
	if p.emit == nil || (method != "item/started" && method != "item/completed") {
		return
	}
	var event struct {
		ThreadID string `json:"threadId"`
		TurnID   string `json:"turnId"`
		Item     struct {
			ID       string          `json:"id"`
			Type     string          `json:"type"`
			Status   string          `json:"status"`
			Command  string          `json:"command"`
			Server   string          `json:"server"`
			Tool     string          `json:"tool"`
			ExitCode *int            `json:"exitCode"`
			Success  *bool           `json:"success"`
			Error    json.RawMessage `json:"error"`
		} `json:"item"`
	}
	if json.Unmarshal(raw, &event) != nil || event.ThreadID != threadID || event.Item.ID == "" || len(event.Item.ID) > 256 {
		return
	}
	if turnID != "" && event.TurnID != "" && event.TurnID != turnID {
		return
	}
	item := event.Item
	kind := ""
	switch item.Type {
	case "commandExecution":
		kind = "command"
		// Count only a direct dws executable as DWS; shell wrappers remain
		// ordinary commands rather than guessing from their arguments.
		words := strings.Fields(item.Command)
		if len(words) > 0 && filepath.Base(strings.Trim(words[0], "\"'")) == "dws" {
			kind = "dws"
		}
	case "mcpToolCall", "dynamicToolCall", "collabAgentToolCall":
		kind = "tool"
		if strings.EqualFold(item.Server, "dws") || strings.HasPrefix(item.Tool, "mcp__dws__") {
			kind = "dws"
		}
	case "webSearch":
		kind = "search"
	case "fileChange":
		kind = "files"
	default:
		return
	}
	if p.seen == nil {
		p.seen = make(map[string]AssistantAgentProgress)
	}
	previous, exists := p.seen[item.ID]
	// Bound each turn's progress stream and prevent duplicate/late starts
	// from reopening completed operations.
	if (!exists && len(p.seen) >= 128) || (exists && previous.Status != "running") {
		return
	}
	status := "running"
	if method == "item/completed" {
		switch item.Status {
		case "failed", "declined":
			status = "failed"
		case "cancelled", "canceled", "interrupted":
			status = "cancelled"
		case "completed":
			status = "completed"
		default:
			status = "finished"
		}
		if item.Success != nil {
			if *item.Success {
				status = "completed"
			} else {
				status = "failed"
			}
		}
		if item.ExitCode != nil {
			if *item.ExitCode == 0 {
				status = "completed"
			} else {
				status = "failed"
			}
		}
		if len(item.Error) > 0 && string(item.Error) != "null" {
			status = "failed"
		}
	}
	if exists {
		kind = previous.Kind
	}
	hash := sha256.Sum256([]byte(item.ID))
	progress := AssistantAgentProgress{Type: "dws_agent_progress", Version: 1, ID: fmt.Sprintf("%x", hash[:8]), Kind: kind, Status: status}
	if exists && progress == previous {
		return
	}
	p.seen[item.ID] = progress
	p.emit(progress)
}

// Keep DWS's native turn input and final response parser. Forward typed
// progress and allowlisted approval callbacks; reject other server requests.
func assistantCodexTurn(ctx context.Context, c *codexAppServerClient, threadID, text string, attachments []connectMediaAttachment, instructions string, emit func(AssistantAgentProgress)) (string, error) {
	id := c.requestID()
	input := []map[string]string{{"type": "text", "text": text}}
	for _, attachment := range attachments {
		if attachment.MediaType == "image" && strings.TrimSpace(attachment.LocalPath) != "" {
			input = append(input, map[string]string{"type": "localImage", "path": attachment.LocalPath})
		}
	}
	params := map[string]any{"input": input, "threadId": threadID}
	if instructions != "" {
		params["additionalContext"] = map[string]any{"dws.digital_employee_policy": map[string]string{"kind": "application", "value": instructions}}
	}
	if err := c.send(map[string]any{"id": id, "method": "turn/start", "params": params}); err != nil {
		return "", err
	}
	progress := assistantCodexProgress{emit: emit}
	turnID := ""
	completedAnswer := ""
	items := make(map[string]json.RawMessage)
	for {
		msg, err := c.next(ctx)
		if err != nil {
			return "", c.withStderr("app-server stream ended before turn/completed", err)
		}
		if msg.ID != nil && msg.Method != "" {
			if err := assistantHandleApproval(ctx, c, msg, threadID, turnID, items); err != nil {
				return "", err
			}
			continue
		}
		if msg.ID != nil && *msg.ID == id {
			if msg.Error != nil {
				return "", fmt.Errorf("turn/start: %s", msg.Error.Message)
			}
			var started struct {
				Turn struct {
					ID string `json:"id"`
				} `json:"turn"`
			}
			if json.Unmarshal(msg.Result, &started) == nil {
				turnID = started.Turn.ID
			}
		}
		progress.handle(msg.Method, msg.Params, threadID, turnID)
		if msg.Method == "item/started" {
			var event struct {
				ThreadID string          `json:"threadId"`
				TurnID   string          `json:"turnId"`
				Item     json.RawMessage `json:"item"`
			}
			var item struct {
				ID   string `json:"id"`
				Type string `json:"type"`
			}
			if json.Unmarshal(msg.Params, &event) == nil && event.ThreadID == threadID && event.TurnID == turnID &&
				json.Unmarshal(event.Item, &item) == nil && item.Type == "fileChange" && len(event.Item) <= 48*1024 && len(items) < 64 {
				items[item.ID] = event.Item
			}
		}
		switch msg.Method {
		case "item/completed":
			var event struct {
				ThreadID string          `json:"threadId"`
				TurnID   string          `json:"turnId"`
				Item     json.RawMessage `json:"item"`
			}
			if json.Unmarshal(msg.Params, &event) == nil && event.ThreadID == threadID &&
				(turnID == "" || event.TurnID == "" || event.TurnID == turnID) {
				answer, err := assistantFinalMessage(event.Item)
				if err != nil {
					return "", err
				}
				if answer != "" {
					completedAnswer = answer
				}
			}
		case "turn/completed":
			var identity struct {
				Turn struct {
					ID    string            `json:"id"`
					Items []json.RawMessage `json:"items"`
				} `json:"turn"`
			}
			if json.Unmarshal(msg.Params, &identity) == nil && turnID != "" && identity.Turn.ID != "" && identity.Turn.ID != turnID {
				continue
			}
			_, status, errMsg, ok := codexTurnCompletedText(msg.Params, threadID)
			if !ok {
				continue
			}
			if status == "interrupted" {
				return "", context.Canceled
			}
			if status == "failed" || errMsg != "" {
				if errMsg == "" {
					errMsg = "turn failed"
				}
				return "", fmt.Errorf("%s", errMsg)
			}
			if status != "completed" {
				return "", fmt.Errorf("agent turn did not complete")
			}
			final := completedAnswer
			for _, item := range identity.Turn.Items {
				answer, err := assistantFinalMessage(item)
				if err != nil {
					return "", err
				}
				if answer != "" {
					final = answer
				}
			}
			// A completed agentMessage can arrive before an empty turn.items.
			// Never substitute commentary or a partly emitted form as final.
			if final == "" {
				return "", errCodexCompletedWithoutReply
			}
			return final, nil
		case "error":
			return "", fmt.Errorf("app-server error notification")
		}
	}
}

func assistantFinalMessage(raw json.RawMessage) (string, error) {
	var item struct{ Type, Phase, Text string }
	if json.Unmarshal(raw, &item) != nil || item.Type != "agentMessage" ||
		(item.Phase != "" && item.Phase != "final_answer") {
		return "", nil
	}
	// Empty phase is the older public agentMessage protocol. Do not retain
	// arbitrary deltas or unbounded output in the progress projection.
	if len(item.Text) > 32_768 {
		return "", fmt.Errorf("agent reply exceeds card limit")
	}
	return strings.TrimSpace(item.Text), nil
}
