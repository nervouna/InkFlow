#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD/build/installer-task/ui"
app="$root/InstallerWindowTests.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>io.damao.inkflow.installer.window-tests</string><key>CFBundleExecutable</key><string>WindowTests</string><key>CFBundlePackageType</key><string>APPL</string><key>NSPrincipalClass</key><string>NSApplication</string></dict></plist>
PLIST
source macOS/scripts/swift-test.sh
build_swift_test installer-window-tests "$app/Contents/MacOS/WindowTests"
"$app/Contents/MacOS/WindowTests" "$root"
