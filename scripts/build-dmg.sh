#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--skip-build" ) ]]; then
  echo "Usage: bash scripts/build-dmg.sh [--skip-build]" >&2
  exit 2
fi
if [[ "${1:-}" != "--skip-build" ]]; then
  bash scripts/build-app.sh
fi

app="$root/dist/DWS Assistant.app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"
app_archs="$(lipo -archs "$app/Contents/MacOS/DWSAssistant")"
helper_archs="$(lipo -archs "$app/Contents/Helpers/dws-assistant-bridge")"
if [[ "$app_archs" != "$helper_archs" ]]; then
  echo "App and helper architectures must match: $app_archs / $helper_archs" >&2
  exit 1
fi
case "$app_archs" in
  arm64|x86_64) architecture="$app_archs" ;;
  'x86_64 arm64'|'arm64 x86_64') architecture=universal ;;
  *) echo "Unsupported architecture: $app_archs" >&2; exit 1 ;;
esac
codesign --verify --deep --strict "$app"

mkdir -p "$root/.build" "$root/dist"
staging="$(mktemp -d "$root/.build/dmg-staging.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/DWS Assistant.app"
ln -s /Applications "$staging/Applications"

filename="DWS-Assistant-$version-$architecture.dmg"
image="$root/dist/$filename"
hdiutil create -volname "DWS Assistant $version" -srcfolder "$staging" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$image"
hdiutil verify "$image"
(
  cd "$root/dist"
  shasum -a 256 "$filename" > "$filename.sha256"
)
echo "Built: $image"
echo "Checksum: $image.sha256"
