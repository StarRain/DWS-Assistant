#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
python3 scripts/make-ui-icons.py
bash scripts/build-bridge.sh
bash scripts/swift.sh build -c release
app="$root/.build/package/DWS Dashboard.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
chmod -R u+w "$app/Contents/Resources/Licenses"
cp .build/release/DWSDashboard "$app/Contents/MacOS/DWSDashboard"
cp .build/bridge/dws-dashboard-bridge "$app/Contents/Helpers/dws-dashboard-bridge"
cp LICENSE "$app/Contents/Resources/Licenses/DWS-Dashboard-LICENSE.txt"
cp NOTICE "$app/Contents/Resources/Licenses/DWS-Dashboard-NOTICE.txt"
cp .build/vendor/dws/LICENSE "$app/Contents/Resources/Licenses/DWS-Apache-2.0.txt"
cp .build/vendor/dws/NOTICE "$app/Contents/Resources/Licenses/DWS-NOTICE.txt"
cp -R .build/bridge/Licenses/. "$app/Contents/Resources/Licenses/"
if [[ -f .build/toolchain/go/LICENSE ]]; then cp .build/toolchain/go/LICENSE "$app/Contents/Resources/Licenses/Go-LICENSE.txt"; fi
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
python3 - "$app" <<'PY'
import plistlib,sys,pathlib
app=pathlib.Path(sys.argv[1])
info={
 'CFBundleDevelopmentRegion':'zh_CN', 'CFBundleDisplayName':'DWS Dashboard',
 'CFBundleName':'DWS Dashboard', 'CFBundleExecutable':'DWSDashboard',
 'CFBundleIdentifier':'local.dws.dashboard', 'CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'1.0.0', 'CFBundleVersion':'1',
 'LSMinimumSystemVersion':'14.0', 'NSHighResolutionCapable':True,
 'NSPrincipalClass':'NSApplication', 'CFBundleIconFile':'AppIcon',
 'NSHumanReadableCopyright':'DWS Dashboard · Includes DWS CLI components under Apache-2.0'
}
with open(app/'Contents/Info.plist','wb') as f:plistlib.dump(info,f)
PY
export CLANG_MODULE_CACHE_PATH="$root/.build/clang-cache"
xcrun swiftc Sources/DWSDashboard/DashboardBrand.swift scripts/make-icon.swift -o "$root/.build/make-icon"
"$root/.build/make-icon" "$root/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app/Contents/Helpers/dws-dashboard-bridge"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$root/dist"
python3 - "$app" "$root/dist/DWS Dashboard.app" "$root/.build/previous-app" <<'PY'
import os,pathlib,shutil,sys
source,target,previous=map(pathlib.Path,sys.argv[1:])
if previous.exists(): shutil.rmtree(previous)
if target.exists(): os.rename(target, previous)
os.rename(source,target)
PY
echo "Built: $root/dist/DWS Dashboard.app"
