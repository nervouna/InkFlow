#!/bin/bash
# Builds and runs the black-box benchmark driver (macOS/Experiments/BlackBoxBenchmark/README.md).
# Run from a logged-in GUI session, outside the sandbox. Everything it produces stays under build/.
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
# exec: SIGINT and SIGTERM reach the driver itself, which restores the input source.
exec "$app/Contents/MacOS/BlackBoxBenchmark" "$@"
