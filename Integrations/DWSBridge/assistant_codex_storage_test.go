// SPDX-License-Identifier: Apache-2.0
package helpers

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestAssistantBridgeDedicatedStorageSharesInputsOnly(t *testing.T) {
	native, dedicated := t.TempDir(), filepath.Join(t.TempDir(), "codex")
	t.Setenv("CODEX_HOME", native)
	for _, name := range []string{"config.toml", "auth.json", "state_5.sqlite", "queue_1.sqlite"} {
		if err := os.WriteFile(filepath.Join(native, name), []byte("private fixture"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"sessions", "thread-writer-locks", "logs"} {
		if err := os.MkdirAll(filepath.Join(native, name), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := assistantPrepareCodexHome(dedicated); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"config.toml", "auth.json"} {
		link, err := os.Readlink(filepath.Join(dedicated, name))
		if err != nil || link != filepath.Join(native, name) {
			t.Fatalf("shared input %s: %v", name, err)
		}
	}
	for _, name := range []string{"state_5.sqlite", "queue_1.sqlite", "sessions", "thread-writer-locks", "logs"} {
		if _, err := os.Lstat(filepath.Join(dedicated, name)); !os.IsNotExist(err) {
			t.Fatalf("desktop state copied: %s", name)
		}
	}
	privateDB := filepath.Join(dedicated, "state_5.sqlite")
	if err := os.WriteFile(privateDB, []byte("panel history"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := assistantPrepareCodexHome(dedicated); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(privateDB)
	if string(data) != "panel history" {
		t.Fatal("overwrote panel state")
	}
	data, _ = os.ReadFile(filepath.Join(native, "state_5.sqlite"))
	if string(data) != "private fixture" {
		t.Fatal("modified desktop state")
	}
	info, _ := os.Stat(dedicated)
	if info.Mode().Perm() != 0700 {
		t.Fatalf("directory permissions: %v", info.Mode())
	}
}

func TestAssistantBridgeStorageRejectsSharedOrUnavailableHome(t *testing.T) {
	native := t.TempDir()
	t.Setenv("CODEX_HOME", native)
	if err := assistantPrepareCodexHome(native); err == nil {
		t.Fatal("accepted desktop home")
	}
	alias := filepath.Join(t.TempDir(), "alias")
	if err := os.Symlink(native, alias); err != nil {
		t.Fatal(err)
	}
	if err := assistantPrepareCodexHome(alias); err == nil {
		t.Fatal("accepted desktop symlink")
	}
	clearChannelEnv(t)
	dir := t.TempDir()
	protocol := assistantCodexLifecycleStub(t, dir, "")
	blocked := filepath.Join(dir, "blocked")
	if err := os.WriteFile(blocked, []byte("not a directory"), 0600); err != nil {
		t.Fatal(err)
	}
	for _, home := range []string{"", blocked, native} {
		req := AssistantAgentRequest{Channel: "codex", ConversationID: "c", ScopeID: "s", Text: "hello", WorkDir: dir, StateDir: t.TempDir(), CodexHome: home, TimeoutSeconds: 10}
		_, err := RunAssistantAgentWithStatus(context.Background(), req)
		if err == nil || AssistantAgentFailureReason(err) != "session_storage_unavailable" {
			t.Fatalf("invalid storage accepted: %v", err)
		}
	}
	if _, err := os.Stat(protocol); !os.IsNotExist(err) {
		t.Fatal("started engine without private storage")
	}
}

func TestAssistantBridgeNewStorageCreatesThenResumesOwnSession(t *testing.T) {
	clearChannelEnv(t)
	native, state, dir := t.TempDir(), t.TempDir(), t.TempDir()
	t.Setenv("CODEX_HOME", native)
	protocol := assistantCodexLifecycleStub(t, dir, "")
	envLog := filepath.Join(dir, "engine-env.json")
	t.Setenv("ASSISTANT_STUB_ENV_LOG", envLog)
	req := AssistantAgentRequest{Channel: "codex", ConversationID: "c", ScopeID: "assistant-codex-v3-test", Text: "new message", WorkDir: dir, StateDir: state, CodexHome: filepath.Join(state, "codex \"中文\""), TimeoutSeconds: 10}
	t.Setenv("DWS_CONFIG_DIR", state)
	oldPath := codexThreadStorePath("assistant-codex-v2-test-project-policy-v1")
	newCodexThreadSessions(oldPath).setThreadID("c", "thr_desktop")
	first, err := RunAssistantAgentWithStatus(context.Background(), req)
	if err != nil || first.SessionAction != "created" {
		t.Fatalf("%+v %v", first, err)
	}
	second, err := RunAssistantAgentWithStatus(context.Background(), req)
	if err != nil || second.SessionAction != "resumed" || second.SessionReference != first.SessionReference {
		t.Fatalf("%+v %v", second, err)
	}
	if newCodexThreadSessions(oldPath).threadID("c") != "thr_desktop" {
		t.Fatal("changed old binding")
	}
	var environment struct {
		Home, SQLite string
		Args         []string
	}
	data, err := os.ReadFile(envLog)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &environment); err != nil {
		t.Fatal(err)
	}
	if environment.Home != req.CodexHome || environment.SQLite != req.CodexHome {
		t.Fatal("reused desktop environment")
	}
	quoted, _ := json.Marshal(req.CodexHome)
	logs, _ := json.Marshal(filepath.Join(req.CodexHome, "logs"))
	args := strings.Join(environment.Args, "\n")
	if !strings.Contains(args, "sqlite_home="+string(quoted)) || !strings.Contains(args, "log_dir="+string(logs)) {
		t.Fatal("storage overrides missing")
	}
	data, _ = os.ReadFile(protocol)
	if strings.Contains(string(data), "thr_desktop") || strings.Contains(string(data), `"method":"thread/fork"`) {
		t.Fatal("used desktop history")
	}
	if strings.Count(string(data), `"method":"thread/start"`) != 1 || strings.Count(string(data), `"method":"thread/resume"`) != 1 {
		t.Fatal("did not retain new session")
	}
}
