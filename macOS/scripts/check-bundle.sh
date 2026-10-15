#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/test-timing.sh
stage_started=$(inkflow_test_timing_now)
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
# One librime, built from source with Lua merged in. An external plugin would be a second runtime.
librime="$app/Contents/Frameworks/librime.1.dylib"
[[ -s "$librime" ]]
# The license texts Resources/Licenses/librime*.txt are not libraries.
[[ "$(find "$app" -name 'librime*' -not -path "$app/Contents/Resources/Licenses/*" | sed "s|^$app/||")" == Contents/Frameworks/librime.1.dylib \
   && ! -e "$app/Contents/Frameworks/rime-plugins" ]] || {
  echo 'The bundle must carry exactly one librime and no plugin.' >&2
  exit 1
}
[[ "$(vtool -show-build "$librime" | awk '$1 == "minos" { print $2 }')" == "$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")" ]] || {
  echo 'librime must target the app minimum macOS version.' >&2
  exit 1
}
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
[[ -s "$app/Contents/Resources/Licenses/Rust/dictionary-crates.txt" ]]
[[ -s "$app/Contents/Resources/Licenses/Rust/COPYRIGHT-library.html" ]]
[[ -s "$app/Contents/Resources/Licenses/Rust/licenses/MIT.txt" ]]
[[ -s "$app/Contents/Resources/Licenses/Rust/licenses/Apache-2.0.txt" ]]
[[ -s "$app/Contents/Resources/Licenses/sparkle.txt" ]]
cmp macOS/Licenses/sparkle.txt "$app/Contents/Resources/Licenses/sparkle.txt"
sparkle_dependency='@rpath/Sparkle.framework/Versions/B/Sparkle'
app_libraries=$(otool -L "$app_binary" | awk 'NR > 1 && /^\t/ {print $1}')
if ! grep -Fqx "$sparkle_dependency" <<< "$app_libraries"; then
  echo "InkFlow does not link the bundled Sparkle framework: $sparkle_dependency" >&2
  exit 1
fi
app_rpaths=$(otool -l "$app_binary" | awk '$1 == "cmd" && $2 == "LC_RPATH" { want=1; next } want && $1 == "path" { print $2; want=0 }')
if ! grep -Fqx '@executable_path/../Frameworks' <<< "$app_rpaths"; then
  echo 'InkFlow is missing the Frameworks runtime search path.' >&2
  exit 1
fi
worker_libraries=$(otool -L "$app/Contents/MacOS/InkFlowDictionaryWorker" | awk 'NR > 1 && /^\t/ {print $1}')
if grep -Fqx "$sparkle_dependency" <<< "$worker_libraries"; then
  echo 'Sparkle must be linked only by InkFlowApp, not the dictionary worker.' >&2
  exit 1
fi
codesign --verify --deep --strict "$sparkle_framework"
for binary in "$app_binary" "$app/Contents/MacOS/InkFlowDictionaryWorker" "$librime" "$sparkle_binary"; do
  xcrun lipo "$binary" -verify_arch arm64
  otool -L "$binary" | awk 'NR>1 && /^\t/ {print $1}' | while read -r dependency; do
    case "$dependency" in
      /usr/lib/*|/System/Library/*) ;;
      @rpath/librime.1.dylib) test -f "$app/Contents/Frameworks/librime.1.dylib" ;;
      @rpath/Sparkle.framework/Versions/B/Sparkle)
        [[ "$binary" == "$app_binary" || "$binary" == "$sparkle_binary" ]] && test -f "$sparkle_binary" ;;
      *) echo "Unbundled dependency: $dependency" >&2; exit 1 ;;
    esac
  done
done
if [[ -f "$app/Contents/_CodeSignature/CodeResources" ]]; then codesign --verify --deep --strict "$app"; fi
echo 'PASS bundle fast: plist, arm64, dylib closure, resource summary and signed structure when present'
inkflow_test_timing_report bundle fast "$stage_started"
[[ "$mode" == deep ]] || exit 0

stage_started=$(inkflow_test_timing_now)
cmp build/AppIcon.icns "$app/Contents/Resources/$app_icon"
cmp macOS/Resources/MenuIconTemplate.tiff "$app/Contents/Resources/MenuIconTemplate.tiff"
bash macOS/scripts/prepare-rime.sh build/expected-rime
diff -qr build/expected-rime "$app/Contents/Resources/Rime"
bash macOS/scripts/prepare-packaged-cache.sh "$app" --verify
for license in boost.txt easy-en-LGPL-3.0.txt easy-en-GPL-3.0.txt librime.txt librime-lua.txt lua.txt glog.txt leveldb.txt marisa.txt yaml-cpp.txt inkflow-rime-crates.txt wordfreq.txt rime-ice.txt rime-frost.txt chinese-dictionaries-NOTICE.txt technology-english-NOTICE.txt pinyin-simp.txt opencc.txt; do
  cmp "macOS/Licenses/$license" "$app/Contents/Resources/Licenses/$license"
done
inkflow_test_timing_report bundle deep-resources "$stage_started"
source macOS/scripts/swift-test.sh
stage_started=$(inkflow_test_timing_now)
build_swift_test bundle-artifact-smoke-tests build/bundle-artifact-smoke-tests
inkflow_test_timing_report bundle artifact-smoke-build "$stage_started"
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-bundle-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
stage_started=$(inkflow_test_timing_now)
DYLD_LIBRARY_PATH="$app/Contents/Frameworks" build/bundle-artifact-smoke-tests "$app" "$user_dir"
inkflow_test_timing_report bundle artifact-smoke-execute "$stage_started"
echo 'PASS bundle deep: rebuilt resources, packaged cache and bundled-runtime smoke'

stage_started=$(inkflow_test_timing_now)
build_swift_test metadata-tests build/metadata-tests
build/metadata-tests "$app"
inkflow_test_timing_report bundle metadata "$stage_started"
