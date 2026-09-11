#!/bin/bash
# Compile and assemble only. Signing/notarization belong to release packaging.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo 'Usage: build-installer.sh /path/to/InkFlow.zip [output.app]' >&2
  exit 2
fi
payload="$1"
output="${2:-build/InkFlow Installer.app}"
[[ -f "$payload" && ! -L "$payload" ]] || { echo 'Payload must be an existing regular ZIP file.' >&2; exit 2; }
[[ "$output" == *.app && ! -e "$output" ]] || { echo 'Output must be a new .app path; existing output is preserved.' >&2; exit 2; }
mkdir -p build/installer-task/compiler
# Reuse the same generated icon as the input method, without building or installing it.
if [[ ! -f build/AppIcon.icns ]]; then
  bash macOS/scripts/build-icon.sh
fi
scratch="$(mktemp -d build/installer-task/compiler/assembly.XXXXXX)"
trap 'rm -rf "$scratch"' EXIT
app="$scratch/InkFlow Installer.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/Payload"
cp macOS/Installer/Info.plist "$app/Contents/Info.plist"
for key in CFBundleShortVersionString CFBundleVersion; do
  value="$(/usr/libexec/PlistBuddy -c "Print :$key" macOS/Info.plist)"
  /usr/libexec/PlistBuddy -c "Set :$key $value" "$app/Contents/Info.plist"
done
cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$payload" "$app/Contents/Resources/Payload/InkFlow.zip"
source macOS/scripts/swift-package.sh
build_swift_product InkFlowInstaller "$app/Contents/MacOS/InkFlowInstaller" release
/usr/bin/plutil -lint "$app/Contents/Info.plist"
mkdir -p "$(dirname "$output")"
mv "$app" "$output"
printf 'Built %s (not Developer ID signed or notarized; no installation performed)\n' "$output"
