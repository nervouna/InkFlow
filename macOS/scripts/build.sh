#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
macOS/scripts/dependencies.sh
source macOS/scripts/swift-package.sh
build_swift_product quality-build-metadata build/quality-build-metadata debug
build_snapshot=$(build/quality-build-metadata "$PWD" --build-snapshot)
# The first build bootstraps the snapshot tool. Re-enter SwiftPM after the snapshot so
# a change during bootstrap cannot leave the embedded metadata tool/source out of sync.
build_swift_product quality-build-metadata build/quality-build-metadata debug
stage_root=$(mktemp -d "$PWD/build/app-stage.XXXXXX")
app="$stage_root/InkFlow.app"
target="$PWD/build/InkFlow.app"
previous="$stage_root/previous.app"
installed=false
cleanup() {
  if [[ "$installed" != true && -d "$previous" && ! -e "$target" ]]; then mv "$previous" "$target"; fi
  rm -rf "$stage_root"
}
trap cleanup EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks/rime-plugins" "$app/Contents/Resources/Rime" "$app/Contents/Resources/Licenses"
cp /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns "$app/Contents/Resources/InputMethod.icns"
bash macOS/scripts/build-icon.sh
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
ditto macOS/Resources "$app/Contents/Resources"
cp macOS/Info.plist "$app/Contents/Info.plist"
cp build/deps/dist/lib/librime.1.17.0.dylib "$app/Contents/Frameworks/librime.1.dylib"
# librime discovers plugins beside its loaded dylib, not beside the executable.
cp build/deps/dist/lib/rime-plugins/librime-lua.dylib "$app/Contents/Frameworks/rime-plugins/librime-lua.dylib"
bash macOS/scripts/prepare-rime.sh "$app/Contents/Resources/Rime"
cp macOS/Licenses/* "$app/Contents/Resources/Licenses/"
build_swift_product InkFlow "$app/Contents/MacOS/InkFlow" debug
bash macOS/scripts/build-dictionary-worker.sh "$app/Contents/MacOS/InkFlowDictionaryWorker"
bash macOS/scripts/prepare-packaged-cache.sh "$app"
INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/quality-metadata.sh "$app"
[[ -s "$app/Contents/Resources/QualityBuild.json" ]] || { echo 'Build did not produce quality metadata.' >&2; exit 1; }
INKFLOW_SKIP_SWIFTPM_BUILD=1 bash macOS/scripts/quality-metadata.sh "$app" --verify
plutil -lint "$app/Contents/Info.plist"
[[ "$(build/quality-build-metadata "$PWD" --build-snapshot)" == "$build_snapshot" ]] || {
  echo 'Build inputs or commit changed during build.' >&2; exit 1;
}
if [[ -e "$target" ]]; then mv "$target" "$previous"; fi
mv "$app" "$target"
installed=true
rm -rf "$previous"
echo "Built $target"
