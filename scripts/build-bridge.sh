#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
revision=f215043e676d6889e1ddce3464828d8b1ec40c31
archive_sha=c0427f5389729129470fe882e477711d01a850919e71faafc2b7019b0d76e144
mkdir -p .build/vendor .build/bridge .build/go-cache .build/go-mod
if [[ ! -f .build/vendor/dws-v1.0.66.tar.gz ]]; then
  curl -fL "https://codeload.github.com/DingTalk-Real-AI/dingtalk-workspace-cli/tar.gz/$revision" -o .build/vendor/dws-v1.0.66.tar.gz
fi
actual_sha="$(shasum -a 256 .build/vendor/dws-v1.0.66.tar.gz | cut -d ' ' -f 1)"
[[ "$actual_sha" == "$archive_sha" ]] || { echo 'DWS archive checksum mismatch' >&2; exit 1; }
if [[ ! -d .build/vendor/dws ]]; then
  tar -xzf .build/vendor/dws-v1.0.66.tar.gz -C .build/vendor
  mv ".build/vendor/dingtalk-workspace-cli-$revision" .build/vendor/dws
fi
source "$root/scripts/legacy-build-compat.sh"
cp Integrations/DWSBridge/assistant_bridge.go .build/vendor/dws/internal/helpers/assistant_bridge.go
cp Integrations/DWSBridge/assistant_bridge_test.go .build/vendor/dws/internal/helpers/assistant_bridge_test.go
cp Integrations/DWSBridge/assistant_channels_test.go .build/vendor/dws/internal/helpers/assistant_channels_test.go
cp Integrations/DWSBridge/assistant_dws_environment_test.go .build/vendor/dws/internal/helpers/assistant_dws_environment_test.go
cp Integrations/DWSBridge/assistant_codex_storage.go .build/vendor/dws/internal/helpers/assistant_codex_storage.go
cp Integrations/DWSBridge/assistant_codex_storage_test.go .build/vendor/dws/internal/helpers/assistant_codex_storage_test.go
cp Integrations/DWSBridge/assistant_codex_permissions.go .build/vendor/dws/internal/helpers/assistant_codex_permissions.go
cp Integrations/DWSBridge/assistant_codex_permissions_test.go .build/vendor/dws/internal/helpers/assistant_codex_permissions_test.go
cp Integrations/DWSBridge/assistant_approvals.go .build/vendor/dws/internal/helpers/assistant_approvals.go
cp Integrations/DWSBridge/assistant_approvals_test.go .build/vendor/dws/internal/helpers/assistant_approvals_test.go
cp Integrations/DWSBridge/assistant_progress.go .build/vendor/dws/internal/helpers/assistant_progress.go
cp Integrations/DWSBridge/assistant_progress_test.go .build/vendor/dws/internal/helpers/assistant_progress_test.go
mkdir -p .build/vendor/dws/cmd/assistant-bridge
cp Integrations/DWSBridge/main.go .build/vendor/dws/cmd/assistant-bridge/main.go
export GOCACHE="$root/.build/go-cache"
export GOMODCACHE="$root/.build/go-mod"
export GOPATH="$root/.build/go-path"
export GOTOOLCHAIN=local
go_bin="${DWS_ASSISTANT_GO:-$root/.build/toolchain/go/bin/go}"
if [[ ! -x "$go_bin" ]]; then go_bin="$(command -v go)"; fi
cd .build/vendor/dws
"$go_bin" build -trimpath -ldflags '-s -w' -o "$root/.build/bridge/dws-assistant-bridge" ./cmd/assistant-bridge
"$go_bin" list -deps -json ./cmd/assistant-bridge > "$root/.build/bridge/modules.json"
python3 "$root/scripts/collect-licenses.py" "$root/.build/bridge/modules.json" "$root/.build/bridge/Licenses"
if [[ "${1:-}" == "--test" ]]; then
  "$go_bin" test ./internal/helpers -run '^TestAssistantBridge' -count=1 -timeout 60s
fi
