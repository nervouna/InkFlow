#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=deep
metadata_option=--verify
while [[ "${1:-}" == --fast || "${1:-}" == --deep || "${1:-}" == --signed ]]; do
  case "$1" in
    --fast|--deep) mode=${1#--} ;;
    --signed) metadata_option=--verify-signed ;;
  esac
  shift
done
[[ $# -le 1 ]] || { echo "Usage: check-bundle.sh [--fast|--deep] [--signed] [app]" >&2; exit 2; }
app="${1:-$PWD/build/InkFlow.app}"
bash macOS/scripts/quality-metadata.sh "$app" "$metadata_option"
plutil -lint "$app/Contents/Info.plist"
[[ "$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist")" == io.damao.inputmethod.inkflow ]]
[[ "$(plutil -extract TISInputSourceID raw "$app/Contents/Info.plist")" == io.damao.inputmethod.inkflow ]]
[[ "$(plutil -extract InputMethodConnectionName raw "$app/Contents/Info.plist")" == io.damao.inputmethod.inkflow_Connection ]]
icon=$(plutil -extract tsInputMethodIconFileKey raw "$app/Contents/Info.plist")
[[ "$icon" == InputMethod.icns && -s "$app/Contents/Resources/$icon" ]]
app_icon=$(plutil -extract CFBundleIconFile raw "$app/Contents/Info.plist")
[[ "$app_icon" == AppIcon.icns && -s "$app/Contents/Resources/$app_icon" ]]
lua_plugin="$app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
[[ -s "$lua_plugin" ]]
sparkle_framework="$app/Contents/Frameworks/Sparkle.framework"
sparkle_binary="$sparkle_framework/Versions/B/Sparkle"
app_binary="$app/Contents/MacOS/InkFlow"
[[ -s "$sparkle_binary" ]]
for link in Autoupdate Headers Modules PrivateHeaders Resources Sparkle Updater.app XPCServices; do
  [[ -L "$sparkle_framework/$link" ]] || {
    echo "Missing Sparkle.framework symlink: $sparkle_framework/$link" >&2
    exit 1
  }
done
[[ "$(readlink "$sparkle_framework/Versions/Current")" == B ]]
[[ "$(readlink "$sparkle_framework/Sparkle")" == Versions/Current/Sparkle ]]
[[ -s "$app/Contents/Resources/Licenses/sparkle.txt" ]]
cmp macOS/Licenses/sparkle.txt "$app/Contents/Resources/Licenses/sparkle.txt"
sparkle_dependency='@rpath/Sparkle.framework/Versions/B/Sparkle'
if ! otool -L "$app_binary" | awk 'NR > 1 && /^\t/ {print $1}' | grep -Fqx "$sparkle_dependency"; then
  echo "InkFlow does not link the bundled Sparkle framework: $sparkle_dependency" >&2
  exit 1
fi
app_rpaths=$(otool -l "$app_binary" | awk '$1 == "cmd" && $2 == "LC_RPATH" { want=1; next } want && $1 == "path" { print $2; want=0 }')
if ! grep -Fqx '@executable_path/../Frameworks' <<< "$app_rpaths"; then
  echo 'InkFlow is missing the Frameworks runtime search path.' >&2
  exit 1
fi
if otool -L "$app/Contents/MacOS/InkFlowDictionaryWorker" \
  | awk 'NR > 1 && /^\t/ {print $1}' | grep -Fqx "$sparkle_dependency"; then
  echo 'Sparkle must be linked only by InkFlowApp, not the dictionary worker.' >&2
  exit 1
fi
codesign --verify --deep --strict "$sparkle_framework"
for plugin in "$app/Contents/Frameworks/rime-plugins"/*; do
  [[ "$plugin" == "$lua_plugin" ]] || { echo "Unexpected engine plugin: $plugin" >&2; exit 1; }
done
for binary in "$app_binary" "$app/Contents/MacOS/InkFlowDictionaryWorker" "$app/Contents/Frameworks/librime.1.dylib" "$lua_plugin" "$sparkle_binary"; do
  xcrun lipo "$binary" -verify_arch arm64
  otool -L "$binary" | awk 'NR>1 && /^\t/ {print $1}' | while read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/librime.1.dylib) test -f "$app/Contents/Frameworks/librime.1.dylib" ;;
      # The plugin's first otool entry is its own LC_ID_DYLIB, not a dependency.
      @rpath/librime-lua.dylib) [[ "$binary" == "$lua_plugin" ]] ;;
      @rpath/Sparkle.framework/Versions/B/Sparkle)
        [[ "$binary" == "$app_binary" || "$binary" == "$sparkle_binary" ]] && test -f "$sparkle_binary" ;;
      *) echo "Unbundled dependency: $dependency" >&2; exit 1 ;;
    esac
  done
done
if [[ -f "$app/Contents/_CodeSignature/CodeResources" ]]; then codesign --verify --deep --strict "$app"; fi
echo 'PASS bundle fast: plist, arm64, dylib closure, resource summary and signed structure when present'
[[ "$mode" == deep ]] || exit 0

cmp build/AppIcon.icns "$app/Contents/Resources/$app_icon"
cmp macOS/Resources/MenuIconTemplate.tiff "$app/Contents/Resources/MenuIconTemplate.tiff"
bash macOS/scripts/prepare-rime.sh build/expected-rime
diff -qr build/expected-rime "$app/Contents/Resources/Rime"
bash macOS/scripts/prepare-packaged-cache.sh "$app" --verify
for license in easy-en-LGPL-3.0.txt easy-en-GPL-3.0.txt librime-lua.txt lua.txt wordfreq.txt rime-ice.txt rime-frost.txt rime-selected.txt chinese-dictionaries-NOTICE.txt technology-english-NOTICE.txt pinyin-simp.txt opencc.txt; do
  cmp "macOS/Licenses/$license" "$app/Contents/Resources/Licenses/$license"
done
source macOS/scripts/swift-test.sh
build_swift_test engine-tests build/bundle-engine-tests
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-bundle-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
DYLD_LIBRARY_PATH="$app/Contents/Frameworks" build/bundle-engine-tests "$app/Contents/Resources/Rime" "$user_dir"
echo 'PASS bundle deep: rebuilt resources, packaged cache and real bundled-engine transcript'

build_swift_test metadata-tests build/metadata-tests
build/metadata-tests "$app"
