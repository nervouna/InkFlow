#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Opt-in real TCC diagnostic. LaunchServices gives the harness its own permission
# identity; directly running its executable can inherit the terminal's permission.
if [[ "${1:-}" == --microphone-reproduction || "${1:-}" == --settings-window-lifecycle ]]; then
  app="$PWD/build/MicrophoneReproduction.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  bash macOS/scripts/build-icon.sh
  cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
  cp macOS/Info.plist "$app/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string io.damao.inkflow.microphone-reproduction "$app/Contents/Info.plist"
  plutil -replace CFBundleName -string MicrophoneReproduction "$app/Contents/Info.plist"
  plutil -replace CFBundleDisplayName -string '墨流麦克风复现' "$app/Contents/Info.plist"
  plutil -replace CFBundleExecutable -string MicrophoneReproduction "$app/Contents/Info.plist"
  for key in ComponentInputModeDict TISInputSourceID InputMethodConnectionName InputMethodServerControllerClass; do
    plutil -remove "$key" "$app/Contents/Info.plist"
  done
  source macOS/scripts/swift-test.sh
  build_swift_test settings-ui-tests "$app/Contents/MacOS/MicrophoneReproduction"
  codesign --force --sign - --entitlements macOS/Debug.entitlements "$app"
  codesign --verify --deep --strict "$app"
  run_dir=$(mktemp -d "$PWD/build/settings-window-run.XXXXXX")
  echo "Settings window diagnostic logs: $run_dir"
  if [[ "$1" == --microphone-reproduction ]]; then
    echo 'Allow microphone access in the harness, then close its window. No recording or IME registration.'
    marker='^END microphone reproduction$'
  else
    marker='^PASS settings window lifecycle:'
  fi
  open -n -W -a "$app" --stdout "$run_dir/output.log" \
    --stderr "$run_dir/error.log" --args "$1"
  cat "$run_dir/output.log" "$run_dir/error.log"
  if ! rg -q "$marker" "$run_dir/output.log"; then
    echo 'Diagnostic exited without its completion marker; inspect the log and crash report.' >&2
    exit 1
  fi
  exit 0
fi
# Build first. This harness never launches or registers the production IME.
app="$PWD/build/SettingsHarness.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp build/InkFlow.app/Contents/Resources/AppIcon.icns "$app/Contents/Resources/"
cp macOS/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string io.damao.inkflow.settings-harness "$app/Contents/Info.plist"
plutil -replace CFBundleExecutable -string SettingsHarness "$app/Contents/Info.plist"
# Keep LSBackgroundOnly and LSUIElement to test production activation behavior.
plutil -remove ComponentInputModeDict "$app/Contents/Info.plist"
plutil -remove TISInputSourceID "$app/Contents/Info.plist"
plutil -remove InputMethodConnectionName "$app/Contents/Info.plist"
plutil -remove InputMethodServerControllerClass "$app/Contents/Info.plist"
source macOS/scripts/swift-test.sh
build_swift_test settings-ui-tests "$app/Contents/MacOS/SettingsHarness"
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-settings-ui.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
"$app/Contents/MacOS/SettingsHarness" "$PWD/build/InkFlow.app/Contents/Resources/Rime" "$user_dir" "$@" | tee "$user_dir/output.log"
if ! rg -q '^PASS settings UI suite: complete$' "$user_dir/output.log"; then
  echo "FAIL settings UI harness exited without completing all requested cases" >&2
  exit 1
fi
