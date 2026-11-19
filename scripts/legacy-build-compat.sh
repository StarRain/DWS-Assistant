#!/bin/bash
# Compatibility for pre-Assistant build environments and generated overlays.
# Sourced only by build-bridge.sh; new builds use DWS_ASSISTANT_GO exclusively.
if [[ -z "${DWS_ASSISTANT_GO:-}" && -n "${DWS_DASHBOARD_GO:-}" ]]; then
  export DWS_ASSISTANT_GO="$DWS_DASHBOARD_GO"
fi
for old_overlay in dashboard_bridge.go dashboard_bridge_test.go \
  dashboard_channels_test.go dashboard_dws_environment_test.go \
  dashboard_codex_storage.go dashboard_codex_storage_test.go \
  dashboard_codex_permissions.go dashboard_codex_permissions_test.go \
  dashboard_progress.go dashboard_progress_test.go; do
  rm -f "$root/.build/vendor/dws/internal/helpers/$old_overlay"
done
rm -f "$root/.build/vendor/dws/cmd/dashboard-bridge/main.go"
rmdir "$root/.build/vendor/dws/cmd/dashboard-bridge" 2>/dev/null || true
