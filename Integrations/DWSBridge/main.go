// SPDX-License-Identifier: Apache-2.0
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/DingTalk-Real-AI/dingtalk-workspace-cli/internal/helpers"
)

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("DWS Assistant bridge / dws v1.0.66 / f215043e676d6889e1ddce3464828d8b1ec40c31")
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "--channels" {
		json.NewEncoder(os.Stdout).Encode(helpers.AssistantAgentStatuses())
		return
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	var request helpers.AssistantAgentRequest
	decoder := json.NewDecoder(io.LimitReader(os.Stdin, 12*1024*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&request); err != nil {
		fail("invalid_request", "invalid_request", helpers.AssistantAgentResult{})
		return
	}
	encoder := json.NewEncoder(os.Stderr)
	var outputMu sync.Mutex
	emitEvent := func(event any) error { outputMu.Lock(); defer outputMu.Unlock(); return encoder.Encode(event) }
	var emit func(helpers.AssistantAgentProgress)
	if request.ReportProgress {
		emit = func(progress helpers.AssistantAgentProgress) { _ = emitEvent(progress) }
	}
	if request.Channel == "codex" && request.PermissionMode == "ask" && request.InteractiveApprovals {
		inputContext := ctx
		replies := make(chan helpers.AssistantApprovalResponse, 1)
		go func() {
			defer close(replies)
			for {
				var response helpers.AssistantApprovalResponse
				if decoder.Decode(&response) != nil {
					return
				}
				select {
				case replies <- response:
				case <-inputContext.Done():
					return
				}
			}
		}()
		ctx = helpers.WithAssistantApprovals(ctx, func(waiting context.Context, approval helpers.AssistantApprovalRequest) (bool, error) {
			if err := emitEvent(approval); err != nil {
				return false, err
			}
			select {
			case response, ok := <-replies:
				return ok && response.Accepts(approval), nil
			case <-waiting.Done():
				return false, waiting.Err()
			}
		})
	}
	result, err := helpers.RunAssistantAgentWithProgress(ctx, request, emit)
	if err != nil {
		fail("official_adapter_failed", helpers.AssistantAgentFailureReason(err), result)
		return
	}
	output := diagnostics(result)
	output["result"] = result.Answer
	output["adapter"] = "dws-official"
	output["version"] = "1.0.66"
	json.NewEncoder(os.Stdout).Encode(output)
}

func diagnostics(result helpers.AssistantAgentResult) map[string]any {
	return map[string]any{"session_recreated": result.SessionRecreated, "session_action": result.SessionAction, "session_reference": result.SessionReference, "session_title_failed": result.SessionTitleFailed}
}

func fail(code, reason string, result helpers.AssistantAgentResult) {
	// Never surface raw engine errors (which may include credentials or message content).
	output := diagnostics(result)
	output["error"] = code
	output["reason"] = reason
	output["is_error"] = true
	json.NewEncoder(os.Stdout).Encode(output)
	os.Exit(1)
}
