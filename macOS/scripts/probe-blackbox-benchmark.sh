#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="$PWD/build/BlackBoxBenchmark.app"
mkdir -p "$app/Contents/MacOS" "$PWD/build/blackbox-benchmark" "$PWD/build/blackbox-module-cache"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.damao.inkflow.blackbox-benchmark</string>
<key>CFBundleExecutable</key><string>BlackBoxBenchmark</string>
<key>CFBundleName</key><string>BlackBoxBenchmark</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
xcrun swiftc -O -swift-version 5 -module-name BlackBoxBenchmark \
    -module-cache-path "$PWD/build/blackbox-module-cache" \
    macOS/Experiments/BlackBoxBenchmark/main.swift -o "$app/Contents/MacOS/BlackBoxBenchmark"
exec "$app/Contents/MacOS/BlackBoxBenchmark" "$@"
