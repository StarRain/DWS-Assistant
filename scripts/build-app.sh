#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root="$PWD"
python3 scripts/make-ui-icons.py
bash scripts/build-bridge.sh
bash scripts/swift.sh build -c release
app="$root/.build/package/DWS Assistant.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources/Licenses"
chmod -R u+w "$app/Contents/Resources/Licenses"
cp -R .build/release/DWSAssistant_DWSAssistant.bundle "$app/Contents/Resources/"
cp .build/release/DWSAssistant "$app/Contents/MacOS/DWSAssistant"
cp .build/bridge/dws-assistant-bridge "$app/Contents/Helpers/dws-assistant-bridge"
cp LICENSE "$app/Contents/Resources/Licenses/DWS-Assistant-LICENSE.txt"
cp NOTICE "$app/Contents/Resources/Licenses/DWS-Assistant-NOTICE.txt"
cp .build/vendor/dws/LICENSE "$app/Contents/Resources/Licenses/DWS-Apache-2.0.txt"
cp .build/vendor/dws/NOTICE "$app/Contents/Resources/Licenses/DWS-NOTICE.txt"
cp -R .build/bridge/Licenses/. "$app/Contents/Resources/Licenses/"
if [[ -f .build/toolchain/go/LICENSE ]]; then cp .build/toolchain/go/LICENSE "$app/Contents/Resources/Licenses/Go-LICENSE.txt"; fi
cp THIRD_PARTY_NOTICES.md "$app/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
python3 - "$app" <<'PY'
import plistlib,sys,pathlib
app=pathlib.Path(sys.argv[1])
info={
 'CFBundleDevelopmentRegion':'en', 'CFBundleDisplayName':'DWS Assistant',
 'CFBundleLocalizations':['en','zh-Hans'],
 'CFBundleName':'DWS Assistant', 'CFBundleExecutable':'DWSAssistant',
 'CFBundleIdentifier':'com.starrain.dwsassistant', 'CFBundlePackageType':'APPL',
 'CFBundleShortVersionString':'1.0.1', 'CFBundleVersion':'3',
 'LSMinimumSystemVersion':'14.0', 'NSHighResolutionCapable':True,
 'NSPrincipalClass':'NSApplication', 'CFBundleIconFile':'AppIcon',
 'NSHumanReadableCopyright':'DWS Assistant · Includes DWS CLI components under Apache-2.0'
}
with open(app/'Contents/Info.plist','wb') as f:plistlib.dump(info,f)
for language, name in [('en', 'DWS Assistant'), ('zh-Hans', 'DWS助手')]:
    directory = app/'Contents/Resources'/f'{language}.lproj'
    directory.mkdir(exist_ok=True)
    (directory/'InfoPlist.strings').write_text(f'"CFBundleDisplayName" = "{name}";\n"CFBundleName" = "{name}";\n')
PY
export CLANG_MODULE_CACHE_PATH="$root/.build/clang-cache"
xcrun swiftc Sources/DWSAssistant/AssistantBrand.swift scripts/make-icon.swift -o "$root/.build/make-icon"
"$root/.build/make-icon" "$root/.build/AppIcon.iconset"
iconutil -c icns .build/AppIcon.iconset -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app/Contents/Helpers/dws-assistant-bridge"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
mkdir -p "$root/dist"
python3 - "$app" "$root/dist/DWS Assistant.app" "$root/.build/previous-app" <<'PY'
import os,pathlib,shutil,sys
source,target,previous=map(pathlib.Path,sys.argv[1:])
if previous.exists(): shutil.rmtree(previous)
if target.exists(): os.rename(target, previous)
os.rename(source,target)
PY
echo "Built: $root/dist/DWS Assistant.app"
