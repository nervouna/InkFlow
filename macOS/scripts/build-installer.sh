#!/bin/bash
# Compile and assemble only. Signing/notarization belong to release packaging.
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# -lt 1 || $# -gt 4 || $# -eq 3 ]]; then
  echo 'Usage: build-installer.sh /path/to/InkFlow.zip [output.app] [verified-executable verified-icon]' >&2
  exit 2
fi
payload="$1"
output="${2:-build/InkFlow Installer.app}"
verified_binary="${3:-}"
verified_icon="${4:-}"
[[ -f "$payload" && ! -L "$payload" ]] || { echo 'Payload must be an existing regular ZIP file.' >&2; exit 2; }
[[ "$output" == *.app && ! -e "$output" ]] || { echo 'Output must be a new .app path; existing output is preserved.' >&2; exit 2; }
mkdir -p build/installer-task/compiler
if [[ -n "$verified_binary" ]]; then
  [[ -f "$verified_binary" && ! -L "$verified_binary" ]] || { echo 'Verified installer executable is missing.' >&2; exit 2; }
  [[ -f "$verified_icon" && ! -L "$verified_icon" ]] || { echo 'Verified installer icon is missing.' >&2; exit 2; }
else
  # Reuse the same generated icon as the input method for non-release local assembly.
  if [[ ! -f build/AppIcon.icns ]]; then bash macOS/scripts/build-icon.sh; fi
  verified_icon=build/AppIcon.icns
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
cp "$verified_icon" "$app/Contents/Resources/AppIcon.icns"
cp "$payload" "$app/Contents/Resources/Payload/InkFlow.zip"
if [[ -n "$verified_binary" ]]; then
  cp "$verified_binary" "$app/Contents/MacOS/InkFlowInstaller"
  chmod +x "$app/Contents/MacOS/InkFlowInstaller"
else
  source macOS/scripts/swift-package.sh
  build_swift_product InkFlowInstaller "$app/Contents/MacOS/InkFlowInstaller" release
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist"
mkdir -p "$(dirname "$output")"
mv "$app" "$output"
printf 'Built %s (not Developer ID signed or notarized; no installation performed)\n' "$output"
