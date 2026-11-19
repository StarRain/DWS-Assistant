// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestAssistantBridgeScriptsKeepDWSLoginEnvironment(t *testing.T) {
	for _, channel := range []string{"codex", "custom"} {
		for _, mode := range []string{"unset", "empty", "configured"} {
			t.Run(channel+"/"+mode, func(t *testing.T) {
				clearChannelEnv(t)
				native, state, dir := t.TempDir(), t.TempDir(), t.TempDir()
				t.Setenv("DWS_CONFIG_DIR", "")
				if mode == "unset" {
					if err := os.Unsetenv("DWS_CONFIG_DIR"); err != nil {
						t.Fatal(err)
					}
				} else if mode == "configured" {
					t.Setenv("DWS_CONFIG_DIR", native)
				}
				original, wasSet := os.LookupEnv("DWS_CONFIG_DIR")
				// A synthetic login marker: no real credentials or remote calls.
				if err := os.WriteFile(filepath.Join(native, "login-fixture"), []byte("signed in"), 0600); err != nil {
					t.Fatal(err)
				}
				t.Setenv("ASSISTANT_DWS_DEFAULT", native)
				probe := filepath.Join(dir, "dws-status.json")
				t.Setenv("ASSISTANT_DWS_STATUS_LOG", probe)
				writeShellExecutable(t, dir, "dws", `
if [ -f "${DWS_CONFIG_DIR:-$ASSISTANT_DWS_DEFAULT}/login-fixture" ]; then
    printf '{"authenticated":true}'
else
    printf '{"authenticated":false}'
fi
`)
				if channel == "codex" {
					assistantCodexLifecycleStub(t, dir, "")
					writeShellExecutable(t, dir, "codex", `
dws auth status --readonly --format json > "$ASSISTANT_DWS_STATUS_LOG"
exec /usr/bin/python3 -u "$ASSISTANT_STUB_SERVER" "$@"
`)
				} else {
					writeShellExecutable(t, dir, "local-agent", `
dws auth status --readonly --format json > "$ASSISTANT_DWS_STATUS_LOG"
printf 'script completed'
`)
				}
				t.Setenv("PATH", dir+":/usr/bin:/bin")
				req := AssistantAgentRequest{Channel: channel, ConversationID: "c", ScopeID: "s", Text: "check script login", WorkDir: dir, StateDir: state, TimeoutSeconds: 10}
				if channel == "codex" {
					req.CodexHome = t.TempDir()
				} else {
					req.AgentCommand = "local-agent"
				}
				for turn := 0; turn < 2; turn++ {
					result, err := RunAssistantAgentWithStatus(context.Background(), req)
					if err != nil {
						t.Fatal(err)
					}
					data, err := os.ReadFile(probe)
					if err != nil {
						t.Fatal(err)
					}
					var status struct {
						Authenticated bool `json:"authenticated"`
					}
					if err := json.Unmarshal(data, &status); err != nil {
						t.Fatal(err)
					}
					if !status.Authenticated {
						t.Error("nested script lost the native DWS login")
					}
					if got, set := os.LookupEnv("DWS_CONFIG_DIR"); got != original || set != wasSet {
						t.Errorf("DWS_CONFIG_DIR leaked: got %q/%v, want %q/%v", got, set, original, wasSet)
					}
					if channel == "codex" {
						expected := "created"
						if turn == 1 {
							expected = "resumed"
						}
						if result.SessionAction != expected {
							t.Errorf("session action=%q, want %q", result.SessionAction, expected)
						}
						path := filepath.Join(state, "connect", req.ScopeID, "codex-threads.json")
						if newCodexThreadSessions(path).threadID(req.ConversationID) != "thr_recovered" {
							t.Error("session binding escaped the assistant state directory")
						}
					}
				}
				entries, err := os.ReadDir(native)
				if err != nil || len(entries) != 1 || entries[0].Name() != "login-fixture" {
					t.Fatalf("native DWS store was modified: %v, %v", entries, err)
				}
			})
		}
	}
}

func TestAssistantBridgeFailedAdapterDoesNotChangeDWSLoginDirectory(t *testing.T) {
	clearChannelEnv(t)
	native, state := t.TempDir(), t.TempDir()
	t.Setenv("DWS_CONFIG_DIR", native)
	// Trigger a constructor error without relying on the machine's installed CLIs.
	original := agentSpecs["codex"]
	spec := original
	spec.bins = []string{"missing-assistant-test-engine"}
	spec.globs = nil
	agentSpecs["codex"] = spec
	defer func() { agentSpecs["codex"] = original }()
	req := AssistantAgentRequest{Channel: "codex", ConversationID: "c", ScopeID: "s", Text: "hello", WorkDir: t.TempDir(), StateDir: state, CodexHome: t.TempDir(), TimeoutSeconds: 10}
	if _, err := RunAssistantAgent(context.Background(), req); err == nil {
		t.Fatal("expected missing engine error")
	}
	if got := os.Getenv("DWS_CONFIG_DIR"); got != native {
		t.Fatalf("failed construction changed the login directory to %q", got)
	}
}

func TestAssistantBridgeTaskMetadataReachesNestedCommands(t *testing.T) {
	clearChannelEnv(t)
	dir := t.TempDir()
	expected := map[string]string{
		"DWS_CONVERSATION_ID": "cid-real==", "DWS_CONVERSATION_NAME": "构建讨论 \"原样\" $(echo data)",
		"DWS_CONVERSATION_TYPE": "group", "DWS_ACCOUNT_PROFILE": "corp:user",
	}
	for key, value := range expected {
		t.Setenv(key, value)
	}
	writeShellExecutable(t, dir, "metadata-agent", `
/usr/bin/python3 - <<'PY'
import json, os, subprocess
keys = ['DWS_CONVERSATION_ID', 'DWS_CONVERSATION_NAME', 'DWS_CONVERSATION_TYPE', 'DWS_ACCOUNT_PROFILE']
values = {key: subprocess.check_output(['/usr/bin/printenv', key], text=True).rstrip('\n') for key in keys}
print(json.dumps(values))
PY
`)
	t.Setenv("PATH", dir+":/usr/bin:/bin")
	req := AssistantAgentRequest{Channel: "custom", AgentCommand: "metadata-agent", ConversationID: "internal-hash", ScopeID: "s", Text: "chat claims another group", WorkDir: dir, StateDir: t.TempDir(), TimeoutSeconds: 10}
	answer, err := RunAssistantAgent(context.Background(), req)
	if err != nil {
		t.Fatal(err)
	}
	var actual map[string]string
	if err := json.Unmarshal([]byte(answer), &actual); err != nil {
		t.Fatal(err)
	}
	for key, value := range expected {
		if actual[key] != value {
			t.Errorf("nested command got %s=%q, want %q", key, actual[key], value)
		}
	}
}
