#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/InkFlow.app"
plutil -lint "$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == io.damao.inputmethod.inkflow ]]
[[ "$(plutil -extract TISInputSourceID raw "$app/Contents/Info.plist")" == io.damao.inputmethod.inkflow ]]
[[ "$(plutil -extract InputMethodConnectionName raw "$app/Contents/Info.plist")" == io.damao.inputmethod.inkflow_Connection ]]
icon=$(plutil -extract tsInputMethodIconFileKey raw "$app/Contents/Info.plist")
[[ "$icon" == InputMethod.icns && -s "$app/Contents/Resources/$icon" ]]
app_icon=$(plutil -extract CFBundleIconFile raw "$app/Contents/Info.plist")
[[ "$app_icon" == AppIcon.icns && -s "$app/Contents/Resources/$app_icon" ]]
cmp build/AppIcon.icns "$app/Contents/Resources/$app_icon"
cmp macOS/Resources/MenuIconTemplate.tiff "$app/Contents/Resources/MenuIconTemplate.tiff"

for binary in "$app/Contents/MacOS/InkFlow" "$app/Contents/Frameworks/librime.1.dylib"; do
  xcrun lipo "$binary" -verify_arch arm64
  otool -L "$binary" | awk 'NR>1 && /^\t/ {print $1}' | while read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/librime.1.dylib) test -f "$app/Contents/Frameworks/librime.1.dylib" ;;
      *) echo "Unbundled dependency: $dependency" >&2; exit 1 ;;
    esac
  done
done
source macOS/scripts/swift-common.sh
rime_library="$app/Contents/Frameworks/librime.1.dylib" rime_rpath="$app/Contents/Frameworks" \
  build_swift_test build/bundle-engine-tests macOS/Tests/EngineTests.swift
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-bundle-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/bundle-engine-tests "$app/Contents/Resources/Rime" "$user_dir"
echo 'PASS bundle: arm64, plist, system/bundled dylib closure, bundled dictionary transcript'

build_swift_test build/metadata-tests macOS/Tests/MetadataTests.swift
build/metadata-tests "$app"
