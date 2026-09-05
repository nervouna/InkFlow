#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
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
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -I macOS/Sources -I build/deps/dist/include macOS/Sources/Engine.m macOS/Sources/Settings.m macOS/Sources/InputController.m macOS/Tests/SettingsUITests.m -framework AppKit -framework InputMethodKit -framework Carbon -L build/deps/dist/lib -lrime -Wl,-rpath,"$PWD/build/deps/dist/lib" -o "$app/Contents/MacOS/SettingsHarness"
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-settings-ui.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
"$app/Contents/MacOS/SettingsHarness" "$PWD/build/InkFlow.app/Contents/Resources/Rime" "$user_dir" "$@"
