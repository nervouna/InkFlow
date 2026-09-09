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
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
  -module-cache-path build/installer-task/compiler/module-cache \
  macOS/Shared/InputSourceManager.swift macOS/Sources/RuntimeStatus.swift \
  macOS/Installer/Installer*.swift macOS/Installer/NativeWindow.swift \
  macOS/Tests/InstallerWindowTests.swift \
  -framework Foundation -framework AppKit -framework Carbon -framework Security \
  -o "$app/Contents/MacOS/WindowTests"
"$app/Contents/MacOS/WindowTests" "$root"
