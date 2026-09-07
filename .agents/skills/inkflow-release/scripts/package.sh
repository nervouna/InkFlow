#!/bin/bash
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  echo 'Usage: bash package.sh (reads repository .release.local.plist; environment overrides)'
  echo 'Package the already validated build; no build, installation, notarization or publication.'
  exit 0
fi
[[ $# -eq 0 ]] || { echo 'Unexpected argument; use --help.' >&2; exit 2; }
cd "$(dirname "$0")/../../../.."
# shellcheck source=release-config.sh
source .agents/skills/inkflow-release/scripts/release-config.sh
load_release_config
identity=$INKFLOW_SIGN_IDENTITY
source_app="$PWD/build/InkFlow.app"
cmp macOS/Info.plist "$source_app/Contents/Info.plist"
version=$(plutil -extract CFBundleShortVersionString raw macOS/Info.plist)
build=$(plutil -extract CFBundleVersion raw macOS/Info.plist)
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ && "$build" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid release version/build.' >&2; exit 1; }
[[ -x "$source_app/Contents/MacOS/InkFlow" ]] || { echo 'Missing built executable.' >&2; exit 1; }
release_dir="$PWD/build/releases/InkFlow-$version-$build"
[[ ! -e "$release_dir" ]] || { echo 'Release output already exists; inspect it before retrying.' >&2; exit 1; }
bash .agents/skills/inkflow-release/scripts/check-credentials.sh
mkdir -p "$(dirname "$release_dir")"
mkdir "$release_dir" # Refuse to overwrite an existing release attempt.
mkdir "$release_dir/stage"
app="$release_dir/stage/InkFlow.app"
ditto "$source_app" "$app"
# Debug symbols remain in the original build, outside the distributed bundle.
find "$app" -name '*.dSYM' -type d -prune -exec rm -rf {} +
signing=(--force --options runtime --timestamp --sign "$identity")
for binary in "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib" "$app/Contents/Frameworks/librime.1.dylib" "$app/Contents/MacOS/InkFlowDictionaryWorker"; do
  codesign "${signing[@]}" "$binary"
done
codesign "${signing[@]}" --entitlements macOS/DeveloperID.entitlements "$app"
codesign --verify --deep --strict --verbose=2 "$app"
metadata=$(codesign -dvvv "$app" 2>&1)
[[ "$metadata" == *'TeamIdentifier=T7976FL2LP'* && "$metadata" == *'Authority=Developer ID Application:'* && "$metadata" == *'Identifier=io.damao.inputmethod.inkflow'* ]] || { echo 'Unexpected signing identity or bundle ID.' >&2; exit 1; }
codesign --display --entitlements - --xml "$app" > "$release_dir/entitlements.plist"
plutil -lint "$release_dir/entitlements.plist" >/dev/null
if [[ "$(plutil -extract com.apple.security.get-task-allow raw "$release_dir/entitlements.plist" 2>/dev/null || true)" == true ]]; then
  echo 'Debug entitlement in release app.' >&2; exit 1
fi
cp .agents/skills/inkflow-release/assets/安装说明.txt "$release_dir/stage/安装说明.txt"
dmg="$release_dir/InkFlow-$version-$build-arm64.dmg"
hdiutil create -volname "InkFlow $version" -srcfolder "$release_dir/stage" -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"
codesign --verify --strict --verbose=2 "$dmg"
printf 'Signed DMG (not yet notarized): %s\n' "$dmg"
