#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/InkFlow.app"
bash macOS/scripts/quality-metadata.sh "$app" --verify
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
bash macOS/scripts/prepare-rime.sh build/expected-rime
diff -qr build/expected-rime "$app/Contents/Resources/Rime"
for license in easy-en-LGPL-3.0.txt easy-en-GPL-3.0.txt librime-lua.txt lua.txt wordfreq.txt rime-ice.txt rime-frost.txt rime-selected.txt chinese-dictionaries-NOTICE.txt technology-english-NOTICE.txt pinyin-simp.txt; do
  cmp "macOS/Licenses/$license" "$app/Contents/Resources/Licenses/$license"
done

lua_plugin="$app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
[[ -s "$lua_plugin" ]]
for plugin in "$app/Contents/Frameworks/rime-plugins"/*; do
  [[ "$plugin" == "$lua_plugin" ]] || { echo "Unexpected engine plugin: $plugin" >&2; exit 1; }
done
for binary in "$app/Contents/MacOS/InkFlow" "$app/Contents/MacOS/InkFlowDictionaryWorker" "$app/Contents/Frameworks/librime.1.dylib" "$lua_plugin"; do
  xcrun lipo "$binary" -verify_arch arm64
  otool -L "$binary" | awk 'NR>1 && /^\t/ {print $1}' | while read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/librime.1.dylib) test -f "$app/Contents/Frameworks/librime.1.dylib" ;;
      # The plugin's first otool entry is its own LC_ID_DYLIB, not a dependency.
      @rpath/librime-lua.dylib) [[ "$binary" == "$lua_plugin" ]] ;;
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
echo 'PASS bundle: arm64, plist, system/bundled dylib and Lua plugin closure, bundled dictionary transcript'

build_swift_test build/metadata-tests macOS/Tests/MetadataTests.swift
build/metadata-tests "$app"
