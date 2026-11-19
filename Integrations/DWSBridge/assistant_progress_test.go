// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func assistantProgressEvent(thread, turn string, item map[string]any) json.RawMessage {
	raw, _ := json.Marshal(map[string]any{"threadId": thread, "turnId": turn, "item": item})
	return raw
}

func TestAssistantBridgeProgressIsTypedPrivateAndMonotonic(t *testing.T) {
	var events []AssistantAgentProgress
	p := assistantCodexProgress{emit: func(e AssistantAgentProgress) { events = append(events, e) }}
	item := map[string]any{"id": "private-item-id", "type": "commandExecution", "command": "/bin/bash -c secret-command", "status": "inProgress"}
	for _, method := range []string{"reasoning/text/delta", "item/agentMessage/delta"} {
		p.handle(method, assistantProgressEvent("thread", "turn", item), "thread", "turn")
	}
	p.handle("item/started", assistantProgressEvent("other", "turn", item), "thread", "turn")
	p.handle("item/started", assistantProgressEvent("thread", "other", item), "thread", "turn")
	if len(events) != 0 {
		t.Fatal("unrelated/private events leaked")
	}
	p.handle("item/started", assistantProgressEvent("thread", "turn", item), "thread", "turn")
	p.handle("item/started", assistantProgressEvent("thread", "turn", item), "thread", "turn")
	item["status"] = "completed"
	item["exitCode"] = 1
	p.handle("item/completed", assistantProgressEvent("thread", "turn", item), "thread", "turn")
	item["exitCode"] = 0
	p.handle("item/completed", assistantProgressEvent("thread", "turn", item), "thread", "turn")
	p.handle("item/started", assistantProgressEvent("thread", "turn", item), "thread", "turn")
	if len(events) != 2 || events[0].Status != "running" || events[1].Status != "failed" || events[0].ID != events[1].ID {
		t.Fatalf("non-monotonic progress: %+v", events)
	}
	raw, _ := json.Marshal(events)
	for _, private := range []string{"private-item-id", "secret-command", "thread", "turn", "/bin/bash"} {
		if strings.Contains(string(raw), private) {
			t.Fatalf("leaked %q", private)
		}
	}
}

func TestAssistantBridgeProgressClassifiesWithoutInventingSuccess(t *testing.T) {
	cases := []struct {
		item         map[string]any
		kind, status string
	}{
		{map[string]any{"type": "commandExecution", "command": "/usr/local/bin/dws chat list", "exitCode": 0}, "dws", "completed"},
		{map[string]any{"type": "commandExecution", "command": "bash -c 'dws chat list'"}, "command", "finished"},
		{map[string]any{"type": "mcpToolCall", "server": "dws", "status": "failed"}, "dws", "failed"},
		{map[string]any{"type": "dynamicToolCall", "tool": "mcp__dws__search", "success": true}, "dws", "completed"},
		{map[string]any{"type": "mcpToolCall", "server": "other", "status": "completed", "error": map[string]any{"message": "private-error"}}, "tool", "failed"},
		{map[string]any{"type": "fileChange", "status": "declined"}, "files", "failed"},
		{map[string]any{"type": "webSearch", "status": "cancelled"}, "search", "cancelled"},
		{map[string]any{"type": "reasoning", "text": "private reasoning"}, "", ""},
		{map[string]any{"type": "agentMessage", "text": "public answer"}, "", ""},
	}
	for i, tc := range cases {
		tc.item["id"] = fmt.Sprint(i)
		var events []AssistantAgentProgress
		p := assistantCodexProgress{emit: func(e AssistantAgentProgress) { events = append(events, e) }}
		p.handle("item/completed", assistantProgressEvent("thread", "turn", tc.item), "thread", "turn")
		if tc.kind == "" {
			if len(events) != 0 {
				t.Fatal(events)
			}
			continue
		}
		if len(events) != 1 || events[0].Kind != tc.kind || events[0].Status != tc.status {
			t.Fatalf("case %d: %+v", i, events)
		}
	}
}

func TestAssistantBridgeProgressIsBoundedButCompletesExistingSteps(t *testing.T) {
	count := 0
	p := assistantCodexProgress{emit: func(AssistantAgentProgress) { count++ }}
	for i := 0; i < 1000; i++ {
		p.handle("item/started", assistantProgressEvent("thread", "turn", map[string]any{"id": fmt.Sprint(i), "type": "webSearch"}), "thread", "turn")
	}
	for i := 0; i < 128; i++ {
		p.handle("item/completed", assistantProgressEvent("thread", "turn", map[string]any{"id": fmt.Sprint(i), "type": "webSearch", "status": "completed"}), "thread", "turn")
	}
	if count != 256 || len(p.seen) != 128 {
		t.Fatalf("events=%d retained=%d", count, len(p.seen))
	}
}

func TestAssistantBridgeProgressTurnPreservesRequestAndFinalAnswer(t *testing.T) {
	input := &bufferWriteCloser{}
	c := unitCodexClient(input,
		codexRPCMessage{ID: codexIntPtr(1), Result: json.RawMessage(`{"turn":{"id":"turn"}}`)},
		codexRPCMessage{Method: "item/started", Params: assistantProgressEvent("thread", "turn", map[string]any{"id": "cmd", "type": "commandExecution", "command": "dws contact search"})},
		codexRPCMessage{Method: "item/completed", Params: assistantProgressEvent("thread", "turn", map[string]any{"id": "cmd", "type": "commandExecution", "exitCode": 0})},
		codexRPCMessage{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"thread","turn":{"id":"other","status":"completed","items":[{"type":"agentMessage","text":"wrong turn"}]}}`)},
		codexRPCMessage{Method: "turn/completed", Params: json.RawMessage(`{"threadId":"thread","turn":{"id":"turn","status":"completed","items":[{"type":"agentMessage","phase":"final_answer","text":"final answer"},{"type":"agentMessage","phase":"commentary","text":"not the answer"}]}}`)},
	)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	var events []AssistantAgentProgress
	answer, err := assistantCodexTurn(ctx, c, "thread", "prompt", []connectMediaAttachment{{MediaType: "image", LocalPath: "/tmp/input.png"}}, "policy", func(e AssistantAgentProgress) { events = append(events, e) })
	if err != nil || answer != "final answer" || len(events) != 2 || events[1].Kind != "dws" || events[1].Status != "completed" {
		t.Fatalf("answer=%q events=%+v err=%v", answer, events, err)
	}
	for _, text := range []string{`"threadId":"thread"`, `"type":"localImage"`, `"path":"/tmp/input.png"`, `"value":"policy"`} {
		if !strings.Contains(input.String(), text) {
			t.Fatalf("request missing %s: %s", text, input.String())
		}
	}
}

func TestAssistantBridgeProgressTurnRequiresSuccessfulFinalCompletion(t *testing.T) {
	for _, tc := range []struct{ phase, status, want string }{
		{"final_answer", "completed", "complete form"}, {"", "completed", "complete form"},
		{"commentary", "completed", ""}, {"final_answer", "interrupted", ""},
		{"final_answer", "failed", ""}, {"final_answer", "inProgress", ""},
	} {
		t.Run(tc.phase+"/"+tc.status, func(t *testing.T) {
			terminal := json.RawMessage(fmt.Sprintf(`{"threadId":"thread","turn":{"id":"turn","status":%q,"items":[]}}`, tc.status))
			c := unitCodexClient(&bufferWriteCloser{},
				codexRPCMessage{ID: codexIntPtr(1), Result: json.RawMessage(`{"turn":{"id":"turn"}}`)},
				codexRPCMessage{Method: "item/agentMessage/delta", Params: json.RawMessage(`{"threadId":"thread","delta":"incomplete private draft"}`)},
				codexRPCMessage{Method: "item/completed", Params: assistantProgressEvent("thread", "turn", map[string]any{"type": "agentMessage", "phase": tc.phase, "text": "complete form"})},
				codexRPCMessage{Method: "turn/completed", Params: terminal},
			)
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			answer, err := assistantCodexTurn(ctx, c, "thread", "prompt", nil, "", func(AssistantAgentProgress) {})
			if answer != tc.want || (err == nil) != (tc.want != "") {
				t.Fatalf("answer=%q err=%v", answer, err)
			}
		})
	}
}
