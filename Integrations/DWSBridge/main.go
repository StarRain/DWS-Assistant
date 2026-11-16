// SPDX-License-Identifier: Apache-2.0
package main

import (
    "context"
    "encoding/json"
    "fmt"
    "io"
    "os"
    "os/signal"
    "syscall"

    "github.com/DingTalk-Real-AI/dingtalk-workspace-cli/internal/helpers"
)

func main() {
    if len(os.Args) == 2 && os.Args[1] == "--version" { fmt.Println("DWS Dashboard bridge / dws v1.0.66 / f215043e676d6889e1ddce3464828d8b1ec40c31"); return }
    if len(os.Args) == 2 && os.Args[1] == "--channels" { json.NewEncoder(os.Stdout).Encode(helpers.DashboardAgentStatuses()); return }
    ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer cancel()
    var request helpers.DashboardAgentRequest
    decoder := json.NewDecoder(io.LimitReader(os.Stdin, 12*1024*1024))
    decoder.DisallowUnknownFields()
    if err := decoder.Decode(&request); err != nil { fail("invalid_request", "invalid_request", helpers.DashboardAgentResult{}); return }
    var emit func(helpers.DashboardAgentProgress)
    if request.ReportProgress {
        encoder := json.NewEncoder(os.Stderr)
        emit = func(progress helpers.DashboardAgentProgress) { _ = encoder.Encode(progress) }
    }
    result, err := helpers.RunDashboardAgentWithProgress(ctx, request, emit)
    if err != nil { fail("official_adapter_failed", helpers.DashboardAgentFailureReason(err), result); return }
    output := diagnostics(result)
    output["result"] = result.Answer; output["adapter"] = "dws-official"; output["version"] = "1.0.66"
    json.NewEncoder(os.Stdout).Encode(output)
}

func diagnostics(result helpers.DashboardAgentResult) map[string]any {
    return map[string]any{"session_recreated": result.SessionRecreated, "session_action": result.SessionAction, "session_reference": result.SessionReference, "session_title_failed": result.SessionTitleFailed}
}

func fail(code, reason string, result helpers.DashboardAgentResult) {
    // Never surface raw engine errors (which may include credentials or message content).
    output := diagnostics(result)
    output["error"] = code; output["reason"] = reason; output["is_error"] = true
    json.NewEncoder(os.Stdout).Encode(output)
    os.Exit(1)
}
