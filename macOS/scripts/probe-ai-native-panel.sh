#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/AINativePanelProbe.app"
mkdir -p "$app/Contents/MacOS" "$PWD/build/native-panel-module-cache"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.damao.inkflow.native-panel-probe</string>
<key>CFBundleExecutable</key><string>AINativePanelProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun clang -fobjc-arc -fblocks -fmodules -fmodules-cache-path="$PWD/build/native-panel-module-cache" \
    -framework AppKit -framework InputMethodKit macOS/Experiments/AINativePanel/main.m \
    -o "$app/Contents/MacOS/AINativePanelProbe"
"$app/Contents/MacOS/AINativePanelProbe" 2>&1 | tee "$app/probe.log"
