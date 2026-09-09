#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 0 || ( $# == 2 && $1 == --live ) ]] || { echo 'Usage: test-ai-native.sh [--live /absolute/path/to/ignored/.env]' >&2; exit 1; }
[[ -f build/test-shared/inkflow_pinyin.schema.yaml ]] || { echo 'Run test.sh first to prepare test-shared.' >&2; exit 1; }
app="$PWD/build/AINativeHarness.app"
mkdir -p "$app/Contents/MacOS"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>io.damao.inkflow.ai-native-harness</string>
<key>CFBundleExecutable</key><string>AINativeHarness</string>
<key>CFBundleName</key><string>墨流 AI 独立验证</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
source macOS/scripts/swift-common.sh
build_swift_test "$app/Contents/MacOS/AINativeHarness" macOS/Tests/AIDiagnosticTestSupport.swift macOS/Tests/AIRuntimeTestSupport.swift macOS/Tests/AILiveConfiguration.swift macOS/Tests/AIControllerNativeTests.swift
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-ai-native.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
"$app/Contents/MacOS/AINativeHarness" "$PWD/build/test-shared" "$user_dir" "$@" | tee "$app/check.log"
rg -q '^PASS native AI:' "$app/check.log" || { echo 'Native harness exited before its final acceptance result.' >&2; exit 1; }
