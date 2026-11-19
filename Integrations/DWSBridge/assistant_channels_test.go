// SPDX-License-Identifier: Apache-2.0
package helpers

import (
    "context"
    "encoding/json"
    "io"
    "net/http"
    "os"
    "os/exec"
    "path/filepath"
    "strings"
    "testing"
)

func TestAssistantBridgeCustomUsesOfficialCommandContract(t *testing.T) {
    clearChannelEnv(t)
    dir := t.TempDir()
    log := filepath.Join(dir, "argv")
    t.Setenv("ASSISTANT_COMMAND_LOG", log)
    t.Setenv("DWS_AGENT_CMD", "/bin/false")
    writeShellExecutable(t, dir, "local-agent", `
printf '%s\n' "$@" > "$ASSISTANT_COMMAND_LOG"
pwd >> "$ASSISTANT_COMMAND_LOG"
printf 'local model answer'
`)
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    prompt := "hello $(touch never-run) `whoami` ; 中文"
    req := AssistantAgentRequest{Channel:"custom", AgentCommand:"local-agent --local-model", ConversationID:"c", ScopeID:"s", Text:prompt, WorkDir:dir, StateDir:t.TempDir(), TimeoutSeconds:10}
    answer, err := RunAssistantAgent(context.Background(), req)
    if err != nil || answer != "local model answer" { t.Fatalf("answer=%q error=%v", answer, err) }
    data, err := os.ReadFile(log); if err != nil { t.Fatal(err) }
    lines := strings.Split(strings.TrimSpace(string(data)), "\n")
    if len(lines) != 3 || lines[0] != "--local-model" || lines[1] != prompt { t.Fatalf("command contract changed: %q", data) }
    actualDir, _ := filepath.EvalSymlinks(dir)
    if lines[2] != dir && lines[2] != actualDir { t.Fatalf("workdir=%q want %q", lines[2], dir) }
    req.AgentCommand = " "
    if _, err := RunAssistantAgent(context.Background(), req); err == nil { t.Fatal("empty custom command accepted") }
    req.Channel = "dsh"
    if _, err := RunAssistantAgent(context.Background(), req); err == nil { t.Fatal("external DSH host accepted as local Agent") }
}

func TestAssistantBridgeBuddyChannelsUseOfficialStreamingAndOptions(t *testing.T) {
    for _, channel := range []string{"codebuddy", "workbuddy"} { t.Run(channel, func(t *testing.T) {
        clearChannelEnv(t)
        dir := t.TempDir(); log := filepath.Join(dir, "argv")
        t.Setenv("ASSISTANT_COMMAND_LOG", log)
        writeShellExecutable(t, dir, "codebuddy", `
printf '%s\n' "$@" > "$ASSISTANT_COMMAND_LOG"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"buddy answer"}'
`)
        t.Setenv("PATH", dir+":/usr/bin:/bin")
        req := AssistantAgentRequest{Channel:channel, ConversationID:"c", ScopeID:"s", Text:"hello", Model:"chosen-model", WorkDir:dir, StateDir:t.TempDir(), TimeoutSeconds:10}
        answer, err := RunAssistantAgent(context.Background(), req)
        if err != nil || answer != "buddy answer" { t.Fatalf("answer=%q error=%v", answer, err) }
        data, _ := os.ReadFile(log)
        if !strings.Contains(string(data), "--model\nchosen-model\n") || !strings.Contains(string(data), "stream-json") || !strings.Contains(string(data), "--session-id") || strings.Contains(string(data), "bypassPermissions") { t.Fatalf("unexpected args: %s", data) }
        req.FullPermission = true
        if _, err := RunAssistantAgent(context.Background(), req); err != nil { t.Fatal(err) }
        data, _ = os.ReadFile(log)
        if !strings.Contains(string(data), "bypassPermissions") || !strings.Contains(string(data), "--resume") { t.Fatalf("official permission/session options missing: %s", data) }
    }) }
}

func TestAssistantBridgeQoderWorkUsesOfficialProtocol(t *testing.T) {
    clearChannelEnv(t)
    dir := t.TempDir()
    _, log := writeQoderStreamStub(t, dir)
    t.Setenv("DWS_QODER_STUB_LOG", log)
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    req := AssistantAgentRequest{Channel:"qoderwork", ConversationID:"c", ScopeID:"s", Text:"hello", WorkDir:dir, StateDir:t.TempDir(), TimeoutSeconds:10}
    if answer, err := RunAssistantAgent(context.Background(), req); err != nil || answer == "" { t.Fatalf("answer=%q error=%v", answer, err) }
}

func TestAssistantBridgePiUsesOfficialJSONProtocol(t *testing.T) {
    clearChannelEnv(t)
    dir := t.TempDir(); log := filepath.Join(dir, "argv")
    t.Setenv("ASSISTANT_COMMAND_LOG", log)
    writeShellExecutable(t, dir, "pi", `
printf '%s\n' "$@" > "$ASSISTANT_COMMAND_LOG"
cat >/dev/null
printf '%s\n' '{"type":"message_end","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"pi answer"}]}}' '{"type":"agent_end"}'
`)
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    req := AssistantAgentRequest{Channel:"pi", ConversationID:"c", ScopeID:"s", Text:"hello", Model:"provider/model", WorkDir:dir, StateDir:t.TempDir(), TimeoutSeconds:10}
    answer, err := RunAssistantAgent(context.Background(), req)
    if err != nil || answer != "pi answer" { t.Fatalf("answer=%q error=%v", answer, err) }
    data, _ := os.ReadFile(log)
    for _, expected := range []string{"--mode\njson", "--model\nprovider/model", "--no-tools", "--session"} {
        if !strings.Contains(string(data), expected) { t.Fatalf("missing %q: %s", expected, data) }
    }
}

type assistantChannelTransport func(*http.Request) (*http.Response, error)
func (f assistantChannelTransport) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestAssistantBridgeOpenCodeUsesOfficialServerAPI(t *testing.T) {
    clearChannelEnv(t)
    var message map[string]any
    transport := assistantChannelTransport(func(r *http.Request) (*http.Response, error) {
        body := "{}"
        switch r.URL.Path {
        case "/session": body = `{"id":"session-test"}`
        case "/session/session-test/message":
            json.NewDecoder(r.Body).Decode(&message)
            body = `{"parts":[{"type":"text","text":"opencode answer"}]}`
        default: t.Errorf("unexpected request: %s", r.URL.Path)
        }
        return &http.Response{StatusCode:http.StatusOK, Header:http.Header{"Content-Type": []string{"application/json"}}, Body:io.NopCloser(strings.NewReader(body))}, nil
    })
    originalExec, originalHealthy, originalPort := opencodeExecCommand, opencodeWaitHealthy, opencodeFreeLocalPort
    defer func() { opencodeExecCommand = originalExec; opencodeWaitHealthy = originalHealthy; opencodeFreeLocalPort = originalPort }()
    var argv []string
    opencodeExecCommand = func(name string, args ...string) *exec.Cmd { argv = args; return exec.Command("/bin/sleep", "30") }
    opencodeFreeLocalPort = func() (int, error) { return 12345, nil }
    opencodeWaitHealthy = func(s *opencodeServer, ctx context.Context, client *opencodeHTTPClient) error { client.httpClient = &http.Client{Transport:transport}; return nil }
    dir := t.TempDir()
    writeShellExecutable(t, dir, "opencode", "exit 1")
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    req := AssistantAgentRequest{Channel:"opencode", ConversationID:"c", ScopeID:"s", Text:"hello", Model:"provider/model", WorkDir:dir, StateDir:t.TempDir(), TimeoutSeconds:10}
    answer, err := RunAssistantAgent(context.Background(), req)
    if err != nil || answer != "opencode answer" { t.Fatalf("answer=%q error=%v", answer, err) }
    if len(argv) < 2 || argv[0] != "serve" || argv[1] != "--pure" { t.Fatalf("server argv=%v", argv) }
    model, ok := message["model"].(map[string]any)
    if !ok || model["providerID"] != "provider" || model["modelID"] != "model" { t.Fatalf("model=%v", message["model"]) }
}

func TestAssistantBridgeStatusUsesOfficialRegistry(t *testing.T) {
    clearChannelEnv(t)
    dir := t.TempDir()
    writeShellExecutable(t, dir, "codebuddy", "exit 99")
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    statuses := AssistantAgentStatuses()
    for _, name := range []string{"qoderwork", "opencode", "workbuddy", "codebuddy", "pi"} {
        if _, ok := statuses[name]; !ok { t.Fatalf("missing channel %s", name) }
    }
    for _, name := range []string{"workbuddy", "codebuddy"} {
        if statuses[name]["installed"] != true || statuses[name]["path"] != filepath.Join(dir,"codebuddy") { t.Fatalf("incorrect status: %v", statuses[name]) }
    }
    if _, ok := statuses["custom"]; ok { t.Fatal("custom has no fixed binary to detect") }
}
