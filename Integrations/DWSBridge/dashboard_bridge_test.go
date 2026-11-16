// SPDX-License-Identifier: Apache-2.0
package helpers

import (
    "context"
    "encoding/json"
    "errors"
    "image"
    "image/png"
    "os/exec"
    "os"
    "path/filepath"
    "strings"
    "testing"
    "time"
)

func dashboardCodexLifecycleStub(t *testing.T, dir, mode string) string {
    t.Helper()
    log := filepath.Join(dir, "protocol.log")
    script := filepath.Join(dir, "server.py")
    t.Setenv("DASHBOARD_STUB_LOG", log)
    t.Setenv("DASHBOARD_STUB_MODE", mode)
    t.Setenv("DASHBOARD_STUB_SERVER", script)
    if err := os.WriteFile(script, []byte(`
import sys, json, os
mode = os.environ["DASHBOARD_STUB_MODE"]
thread = ""
def emit(value):
    print(json.dumps(value), flush=True)
for line in sys.stdin:
    with open(os.environ["DASHBOARD_STUB_LOG"], "a") as out: out.write(line)
    call = json.loads(line)
    method, params, rid = call["method"], call.get("params", {}), call.get("id")
    def result(value): emit({"id":rid,"result":value})
    def error(message): emit({"id":rid,"error":{"code":-32600,"message":message}})
    if method == "initialize": result({})
    elif method == "initialized": pass
    elif method == "config/read": result({"config":{"model":"engine-default","model_reasoning_effort":"medium"}})
    elif method == "model/list": result({"data":[{"model":"engine-default","isDefault":True}],"nextCursor":None})
    elif method == "thread/resume":
        thread = params["threadId"]
        if mode.startswith("missing") and thread == "thr_missing":
            error("no rollout found for thread id " + thread)
        elif mode == "resume_denied": error("Unauthorized secret-do-not-expose")
        elif mode == "resume_eof": sys.exit(1)
        else:
            if mode == "rotated" and thread == "thr_existing": thread = "thr_rotated"
            result({"thread":{"id":thread}})
    elif method == "thread/start":
        if mode == "missing_start_failed": error("start failed secret-do-not-expose")
        else:
            thread = "thr_recovered"
            result({"thread":{"id":thread}})
    elif method == "turn/start":
        if params["threadId"] != thread: error("wrong thread")
        else:
            result({"turn":{"id":"turn_fixture"}})
            if mode == "turn_eof": sys.exit(1)
            turn = {"id":"turn_fixture","status":"completed","items":[{"type":"agentMessage","id":"msg","text":"recovered answer"}]}
            if mode.endswith("turn_failed"):
                turn = {"id":"turn_fixture","status":"failed","error":{"message":"execution failed secret-do-not-expose"}}
            emit({"method":"turn/completed","params":{"threadId":thread,"turn":turn}})
    elif method == "thread/name/set":
        if mode == "name_failed": error("name failed secret-do-not-expose")
        else: result({})
    else: error("unexpected method")
`), 0600); err != nil { t.Fatal(err) }
    writeShellExecutable(t, dir, "codex", `exec /usr/bin/python3 -u "$DASHBOARD_STUB_SERVER"`)
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    return log
}

func TestDashboardBridgeRecoversOnlyExplicitlyMissingCodexSession(t *testing.T) {
    cases := []struct{
        mode string
        wantError, recreated bool
        starts, turns int
        binding string
    }{
        {"missing", false, true, 1, 1, "thr_recovered"},
        {"resume_denied", true, false, 0, 0, "thr_existing"},
        {"resume_eof", true, false, 0, 0, "thr_existing"},
        {"turn_failed", true, false, 0, 1, "thr_existing"},
        {"turn_eof", true, false, 0, 1, "thr_existing"},
        {"missing_turn_failed", true, true, 1, 1, "thr_recovered"},
        {"missing_start_failed", true, false, 1, 0, "thr_missing"},
        {"rotated", false, false, 0, 1, "thr_rotated"},
    }
    for _, tc := range cases { t.Run(tc.mode, func(t *testing.T) {
        clearChannelEnv(t)
        dir, state := t.TempDir(), t.TempDir()
        log := dashboardCodexLifecycleStub(t, dir, tc.mode)
        t.Setenv("DWS_CONFIG_DIR", state)
        req := DashboardAgentRequest{Channel:"codex",ConversationID:"conversation",ScopeID:"scope",Text:"current request",WorkDir:dir,StateDir:state,TimeoutSeconds:10}
        path := codexThreadStorePath(req.ScopeID+"-project-policy-v1")
        seed := "thr_existing"
        if strings.HasPrefix(tc.mode, "missing") { seed = "thr_missing" }
        newCodexThreadSessions(path).setThreadID(req.ConversationID, seed)
        result, err := RunDashboardAgentWithStatus(context.Background(), req)
        if (err != nil) != tc.wantError || result.SessionRecreated != tc.recreated { t.Fatalf("result=%+v err=%v", result, err) }
        if !tc.wantError && result.Answer != "recovered answer" { t.Fatalf("answer=%q", result.Answer) }
        if got := newCodexThreadSessions(path).threadID(req.ConversationID); got != tc.binding { t.Fatalf("binding=%q want=%q",got,tc.binding) }
        bytes, _ := os.ReadFile(log); protocol := string(bytes)
        if strings.Count(protocol, `"method":"thread/start"`) != tc.starts || strings.Count(protocol, `"method":"turn/start"`) != tc.turns { t.Fatalf("unexpected retries: %s",protocol) }
        if tc.mode == "missing" || tc.mode == "rotated" {
            again, err := RunDashboardAgentWithStatus(context.Background(), req)
            if err != nil || again.SessionRecreated || again.SessionAction != "resumed" || again.SessionReference != result.SessionReference { t.Fatalf("restart did not reuse binding: %+v %v",again,err) }
            bytes, _ := os.ReadFile(log)
            if strings.Count(string(bytes), `"method":"thread/start"`) != tc.starts { t.Fatal("created another thread on second message") }
        }
    }) }
}

func TestDashboardBridgeAdoptsLegacyBindingAndKeepsCurrentSettings(t *testing.T) {
    for _, mode := range []string{"exact","latest"} { t.Run(mode,func(t *testing.T) {
        clearChannelEnv(t)
        dir, state := t.TempDir(), t.TempDir()
        log := dashboardCodexLifecycleStub(t, dir, "")
        t.Setenv("DWS_CONFIG_DIR", state)
        req := DashboardAgentRequest{Channel:"codex",ConversationID:"conversation",ScopeID:"dashboard-codex-v2-stable",LegacyScopeID:"dashboard-old-exact",Text:"current request",WorkDir:dir,StateDir:state,TimeoutSeconds:10,Model:"new-model",ReasoningEffort:"low",SessionTitle:"项目打包助手",FullPermission:true,AuthorizedDirectories:[]string{dir}}
        legacy := codexThreadStorePath("dashboard-old-other-project-policy-v1")
        newCodexThreadSessions(legacy).setThreadID(req.ConversationID,"thr_other")
        newCodexThreadSessions(codexThreadStorePath("dashboard-other-route-project-policy-v1")).setThreadID("other-conversation","thr_unrelated")
        expected := "thr_other"
        if mode == "exact" {
            exactPath := codexThreadStorePath(req.LegacyScopeID+"-project-policy-v1")
            newCodexThreadSessions(exactPath).setThreadID(req.ConversationID,"thr_exact")
            os.Chtimes(exactPath,time.Unix(1,0),time.Unix(1,0))
            expected = "thr_exact"
        }
        result, err := RunDashboardAgentWithStatus(context.Background(), req)
        if err != nil || result.SessionAction != "resumed" || result.SessionTitleFailed { t.Fatalf("%+v %v",result,err) }
        path := codexThreadStorePath(req.ScopeID+"-project-policy-v1")
        if got := newCodexThreadSessions(path).threadID(req.ConversationID); got != expected { t.Fatalf("adopted %q want %q",got,expected) }
        bytes, _ := os.ReadFile(log)
        if strings.Contains(string(bytes), `"method":"thread/start"`) { t.Fatal("upgrade created a new session") }
        for _, line := range strings.Split(strings.TrimSpace(string(bytes)),"\n") {
            var call struct {Method string `json:"method"`; Params map[string]any `json:"params"`}
            if err := json.Unmarshal([]byte(line),&call); err != nil {t.Fatal(err)}
            switch call.Method {
            case "thread/resume":
                if call.Params["model"]!="new-model" || call.Params["sandbox"]!="workspace-write" || call.Params["cwd"]!=dir || call.Params["excludeTurns"]!=true { t.Fatal("resume omitted current model/permissions/directory") }
            case "thread/name/set":
                if call.Params["threadId"]!=expected || call.Params["name"]!=req.SessionTitle { t.Fatal("title was not applied to bound thread") }
            }
        }
        req.Model="next-model"; req.ReasoningEffort="max"; req.FullPermission=false; req.TimeoutSeconds=20; req.SessionTitle="新名称"; req.LegacyScopeID="dashboard-old-new-settings"
        again, err := RunDashboardAgentWithStatus(context.Background(),req)
        if err!=nil || again.SessionReference!=result.SessionReference {t.Fatalf("settings change split session: %+v %v",again,err)}
        bytes, _ = os.ReadFile(log)
        if strings.Contains(string(bytes), `"method":"thread/start"`) {t.Fatal("settings change created a thread")}
        req.Model=""; req.ReasoningEffort=""; req.AdditionalDirectories=nil
        inherited,err:=RunDashboardAgentWithStatus(context.Background(),req)
        if err!=nil || inherited.SessionReference!=result.SessionReference {t.Fatalf("following defaults split session: %+v %v",inherited,err)}
        bytes,_=os.ReadFile(log)
        var lastResume map[string]any
        for _,line:=range strings.Split(strings.TrimSpace(string(bytes)),"\n") {
            var call struct {Method string `json:"method"`; Params map[string]any `json:"params"`}
            json.Unmarshal([]byte(line),&call)
            if call.Method=="thread/resume" {lastResume=call.Params}
        }
        overrides,_:=lastResume["config"].(map[string]any)
        roots,_:=overrides["sandbox_workspace_write.writable_roots"].([]any)
        if lastResume["model"]!="engine-default" || overrides["model_reasoning_effort"]!="medium" || len(roots)!=0 || lastResume["sandbox"]!="read-only" {t.Fatal("resume retained stale settings")}
    }) }
}

func TestDashboardBridgeTitleFailureDoesNotReplayOrLoseAnswer(t *testing.T) {
    clearChannelEnv(t)
    dir, state := t.TempDir(), t.TempDir()
    log := dashboardCodexLifecycleStub(t,dir,"name_failed")
    req:=DashboardAgentRequest{Channel:"codex",ConversationID:"c",ScopeID:"s",Text:"hello",WorkDir:dir,StateDir:state,TimeoutSeconds:10,SessionTitle:"自定义名称"}
    result, err:=RunDashboardAgentWithStatus(context.Background(),req)
    if err!=nil || result.Answer!="recovered answer" || !result.SessionTitleFailed {t.Fatalf("%+v %v",result,err)}
    bytes,_:=os.ReadFile(log)
    if strings.Count(string(bytes),`"method":"turn/start"`)!=1 {t.Fatal("title failure replayed the task")}
}

func TestDashboardBridgeDiagnosticsUseSafeCategories(t *testing.T) {
    for _, tc:=range []struct{err error; reason string}{
        {context.DeadlineExceeded,"engine_timeout"},
        {context.Canceled,"cancelled"},
        {errDashboardSessionStorage,"session_storage_failed"},
        {errCodexEmployeeResumeFailed,"session_resume_failed"},
        {errors.New("Unauthorized secret-do-not-expose"),"authentication_required"},
        {errors.New("workdir unavailable"),"directory_unavailable"},
        {errors.New("unknown secret-do-not-expose"),"engine_failed"},
    } {
        if got:=DashboardAgentFailureReason(tc.err); got!=tc.reason {t.Fatalf("reason=%q want=%q",got,tc.reason)}
    }
}

func TestDashboardBridgeStopsBeforeTurnWhenBindingCannotPersist(t *testing.T) {
    clearChannelEnv(t)
    dir, state := t.TempDir(), t.TempDir()
    log := dashboardCodexLifecycleStub(t,dir,"")
    if err:=os.WriteFile(filepath.Join(state,"connect"),[]byte("blocked fixture"),0600); err!=nil {t.Fatal(err)}
    req:=DashboardAgentRequest{Channel:"codex",ConversationID:"c",ScopeID:"s",Text:"hello",WorkDir:dir,StateDir:state,TimeoutSeconds:10}
    _, err:=RunDashboardAgentWithStatus(context.Background(),req)
    if !errors.Is(err,errDashboardSessionStorage) {t.Fatalf("expected storage failure: %v",err)}
    bytes,_:=os.ReadFile(log)
    if strings.Contains(string(bytes),`"method":"turn/start"`) {t.Fatal("executed without a persistent session binding")}
}

func TestDashboardBridgeOfficialCodexProtocolAndIsolation(t *testing.T) {
    clearChannelEnv(t)
    t.Setenv("DWS_CONFIG_DIR", t.TempDir())
    dir := t.TempDir()
    log := filepath.Join(dir, "protocol.log")
    t.Setenv("CODEX_STUB_LOG", log)
    argsLog := filepath.Join(dir, "args.log")
    t.Setenv("CODEX_STUB_ARGS", argsLog)
    writeShellExecutable(t, dir, "codex", `
printf '%s\n' "$*" >> "$CODEX_STUB_ARGS"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$CODEX_STUB_LOG"
  case "$line" in
    *\"method\":\"initialize\"*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *\"method\":\"thread/start\"*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_fixture"}}}' ;;
    *\"method\":\"thread/resume\"*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr_fixture"}}}' ;;
    *\"method\":\"turn/start\"*)
      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn_fixture"}}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thr_fixture","turnId":"turn_fixture","itemId":"msg_fixture","delta":"mock official reply"}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr_fixture","turnId":"turn_fixture","item":{"type":"agentMessage","id":"msg_fixture","text":"mock official reply"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr_fixture","turn":{"id":"turn_fixture","status":"completed","items":[{"id":"msg_fixture","type":"agentMessage","text":"mock official reply"}]}}}'
      ;;
  esac
done
`)
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    extra := filepath.Join(dir, `notes "中文"`); if err := os.Mkdir(extra, 0700); err != nil { t.Fatal(err) }
    req := DashboardAgentRequest{AdditionalDirectories: []string{dir, extra}, Channel: "codex", Model: "fixture-model", ConversationID: "group-a", ScopeID: "scope-a", Text: "hello", WorkDir: dir, StateDir: t.TempDir(), TimeoutSeconds: 10, ReasoningEffort: "low"}
    req.AuthorizedDirectories = []string{dir, extra}
    rules := []map[string]string{{"name":"项目打包","content":"收到打包请求时执行授权目录里的 scripts/build.sh"}}
    for i:=0; i<150; i++ { rules = append(rules, map[string]string{"name":"回复约定", "content":strings.Repeat("内容", 100)}) }
    ruleJSON, err := json.Marshal(rules); if err != nil { t.Fatal(err) }
    customRules := string(ruleJSON)
    req.CustomRules = customRules
    t.Setenv("DWS_CONFIG_DIR", req.StateDir)
    newCodexThreadSessions(codexThreadStorePath(req.ScopeID)).setThreadID(req.ConversationID, "legacy_attachment_only_thread")
    req.ImagePaths = []string{dashboardTestImage(t, req.StateDir)}
    for i:=0; i<2; i++ {
        answer, err := RunDashboardAgent(context.Background(), req)
        if err != nil || !strings.Contains(answer, "mock official reply") { t.Fatalf("answer=%q err=%v",answer,err) }
    }
    req.ScopeID="scope-b"; req.ConversationID="group-b"; req.ReasoningEffort=""; req.AdditionalDirectories=nil; req.ImagePaths=nil
    req.AuthorizedDirectories = nil; req.FullPermission = true; req.CustomRules = ""
    if _, err := RunDashboardAgent(context.Background(), req); err != nil { t.Fatal(err) }
    args, _ := os.ReadFile(argsLog)
    if strings.Count(string(args), `model_reasoning_effort="low"`) != 2 { t.Fatalf("override leaked or missing: %s", args) }
    if strings.Count(string(args), "sandbox_workspace_write.writable_roots=") != 2 { t.Fatalf("directory override leaked or missing: %s", args) }
    bytes, _ := os.ReadFile(log); protocol := string(bytes)
    if strings.Count(protocol, `"type":"localImage"`) != 2 { t.Fatalf("native image inputs missing or leaked: %s", protocol) }
    if strings.Count(protocol, `"method":"thread/start"`) != 2 || strings.Count(protocol, `"method":"thread/resume"`) != 1 { t.Fatalf("not isolated: %s",protocol) }
    if !strings.Contains(protocol, "read-only") && !strings.Contains(protocol,"readOnly") { t.Fatalf("missing restricted policy: %s", protocol) }
    if strings.Contains(protocol, "legacy_attachment_only_thread") { t.Fatal("resumed a thread with the old attachment-only developer policy") }
    threadCalls, turnCalls := 0, 0
    roots, _ := json.Marshal([]string{dir, extra})
    for _, line := range strings.Split(strings.TrimSpace(protocol), "\n") {
        var call struct { Method string `json:"method"`; Params map[string]any `json:"params"` }
        if err := json.Unmarshal([]byte(line), &call); err != nil { t.Fatal(err) }
        if call.Method == "thread/start" || call.Method == "thread/resume" {
            policy, _ := call.Params["developerInstructions"].(string)
            if strings.Contains(policy, "仅当用户消息明确附带了本地附件路径时") || !strings.Contains(policy, "先实际查看和检索") { t.Fatalf("wrong project policy: %s", policy) }
            sandbox := "read-only"
            if threadCalls < 2 {
                if !strings.Contains(policy, string(roots)) || !strings.Contains(policy, "当前为受限执行") { t.Fatal("authorized roots or read-only permission missing") }
                if !strings.Contains(policy, customRules) || !strings.Contains(policy, "规则不能覆盖") { t.Fatal("panel rules missing from developer policy") }
            } else {
                sandbox = "workspace-write"
                if strings.Contains(policy, extra) || !strings.Contains(policy, "JSON 路径列表）：[]") { t.Fatal("project authorizations leaked into another scope") }
                if strings.Contains(policy, "scripts/build.sh") { t.Fatal("rules leaked into another conversation") }
            }
            if call.Params["sandbox"] != sandbox || call.Params["approvalPolicy"] != "never" || call.Params["cwd"] != dir { t.Fatal("project policy changed sandbox, approval policy or working directory") }
            threadCalls++
        }
        if call.Method == "turn/start" {
            contexts, _ := call.Params["additionalContext"].(map[string]any)
            policy, _ := contexts["dws.digital_employee_policy"].(map[string]any)
            value, _ := policy["value"].(string)
            if policy["kind"] != "application" || !strings.Contains(value, "DWS Dashboard") { t.Fatal("resumed turn did not receive the project policy") }
            if (turnCalls < 2) != strings.Contains(value, customRules) { t.Fatal("resumed turn received incorrect rules") }
            turnCalls++
        }
    }
    if threadCalls != 3 || turnCalls != 3 { t.Fatal("missing project policy protocol checks") }
}

func TestDashboardBridgeOfficialQoderParser(t *testing.T) {
    clearChannelEnv(t)
    t.Setenv("DWS_CONFIG_DIR", t.TempDir())
    dir:=t.TempDir()
    _, log := writeQoderStreamStub(t,dir)
    t.Setenv("DWS_QODER_STUB_LOG",log)
    t.Setenv("PATH",dir+":"+os.Getenv("PATH"))
    var captured []string
    original := qoderExecCommand
    defer func() { qoderExecCommand = original }()
    qoderExecCommand = func(name string, args ...string) *exec.Cmd { captured = append([]string(nil), args...); return original(name, args...) }
    req:=DashboardAgentRequest{Channel:"qoder",ConversationID:"contact-a",ScopeID:"scope-qoder",Text:"hello",WorkDir:dir,StateDir:t.TempDir(),TimeoutSeconds:10,ReasoningEffort:"max",AdditionalDirectories:[]string{dir}}
    answer,err:=RunDashboardAgent(context.Background(),req)
    if err!=nil || answer=="" {t.Fatalf("answer=%q err=%v",answer,err)}
    if strings.Join(captured[:4], "|") != "--reasoning-effort|max|--add-dir|"+dir { t.Fatalf("missing qoder options: %v", captured) }
}

func TestDashboardBridgeRejectsAPIGeminiAndInvalidRequests(t *testing.T) {
    for _, req:=range []DashboardAgentRequest{{Channel:"gemini"},{Channel:"codex"},{Channel:"codex",ReasoningEffort:"invalid"},{Channel:"qoder",ReasoningEffort:"low"}} {
        if _,err:=RunDashboardAgent(context.Background(),req);err==nil {t.Fatal("expected validation error before any real engine launch")}
    }
    for _, rules := range []string{"not-json", "null", "[]", `[{"name":"", "content":"missing name"}]`, strings.Repeat(" ", 4*1024*1024+1)} {
        req := DashboardAgentRequest{Channel:"codex",ConversationID:"c",ScopeID:"s",Text:"hello",CustomRules:rules}
        if _, err := RunDashboardAgent(context.Background(), req); err == nil || !strings.Contains(err.Error(), "rule") { t.Fatalf("invalid rules reached engine setup: %v", err) }
    }
}

func TestDashboardBridgeClaudeOptionsKeepLiteralDirectoriesAndEngineDefault(t *testing.T) {
    clearChannelEnv(t)
    t.Setenv("DWS_CONFIG_DIR", t.TempDir())
    dir := t.TempDir()
    extra := filepath.Join(dir, `folder "with spaces"`)
    if err := os.Mkdir(extra, 0700); err != nil { t.Fatal(err) }
    log := filepath.Join(dir, "claude-args")
    t.Setenv("CLAUDE_STUB_ARGS", log)
    writeShellExecutable(t, dir, "claude", `
printf '%s\n' "$@" > "$CLAUDE_STUB_ARGS"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"mock reply"}'
`)
    t.Setenv("PATH",dir+":/usr/bin:/bin")
    req := DashboardAgentRequest{Channel:"claudecode",ConversationID:"c",ScopeID:"s",Text:"hello",WorkDir:dir,StateDir:t.TempDir(),TimeoutSeconds:10,ReasoningEffort:"xhigh",AdditionalDirectories:[]string{dir,extra}}
    req.ImagePaths = []string{dashboardTestImage(t, req.StateDir)}
    req.Text += "\n查看附图: " + req.ImagePaths[0]
    if _, err := RunDashboardAgent(context.Background(), req); err != nil { t.Fatal(err) }
    data, err := os.ReadFile(log); if err != nil { t.Fatal(err) }
    args := string(data)
    if !strings.Contains(args, "--effort\nxhigh\n") || !strings.Contains(args, "--add-dir\n"+extra+"\n") { t.Fatalf("missing literal options: %s", args) }
    if strings.Contains(args, "claude-haiku") || strings.Contains(args,"bypassPermissions") { t.Fatalf("default model pinned or permissions expanded: %s", args) }
    if !strings.Contains(args, "--allowedTools\nRead\n") || !strings.Contains(args, filepath.Dir(req.ImagePaths[0])) { t.Fatalf("image read access missing: %s", args) }
    req.AdditionalDirectories=[]string{"relative"}
    if _, err := RunDashboardAgent(context.Background(), req); err == nil { t.Fatal("relative authorization directory accepted") }
}

func dashboardTestImage(t *testing.T, stateDir string) string {
    t.Helper()
    folder := filepath.Join(filepath.Dir(stateDir), "image-cache", "turn-test")
    if err := os.MkdirAll(folder, 0700); err != nil { t.Fatal(err) }
    path := filepath.Join(folder, "image.png")
    file, err := os.Create(path); if err != nil { t.Fatal(err) }
    if err = png.Encode(file, image.NewRGBA(image.Rect(0,0,2,2))); err != nil { t.Fatal(err) }; file.Close()
    path, err = filepath.EvalSymlinks(path); if err != nil { t.Fatal(err) }; return path
}

func TestDashboardBridgeQoderImageKeepsNativeAttachmentAndEffort(t *testing.T) {
    clearChannelEnv(t)
    dir := t.TempDir(); log := filepath.Join(dir, "args")
    t.Setenv("DASHBOARD_ARGS", log)
    writeShellExecutable(t, dir, "qodercli", `
printf '%s\n' "$@" > "$DASHBOARD_ARGS"
printf 'image answer'
`)
    t.Setenv("PATH", dir+":/usr/bin:/bin")
    req := DashboardAgentRequest{Channel:"qoder",ConversationID:"c",ScopeID:"s",Text:"describe",WorkDir:dir,StateDir:t.TempDir(),TimeoutSeconds:10,ReasoningEffort:"max",AdditionalDirectories:[]string{dir}}
    req.ImagePaths = []string{dashboardTestImage(t, req.StateDir)}
    answer, err := RunDashboardAgent(context.Background(), req)
    if err != nil || answer != "image answer" { t.Fatalf("answer=%q err=%v", answer, err) }
    data, _ := os.ReadFile(log); args := string(data)
    for _, part := range []string{"--reasoning-effort\nmax", "--attachment\n"+req.ImagePaths[0], "--tools\n\n", "--add-dir\n"+dir} {
        if !strings.Contains(args, part) { t.Fatalf("missing %q: %s", part, args) }
    }
    req.ImagePaths = []string{filepath.Join(dir,"outside.png")}
    if _, err := RunDashboardAgent(context.Background(), req); err == nil { t.Fatal("outside image accepted") }
}
