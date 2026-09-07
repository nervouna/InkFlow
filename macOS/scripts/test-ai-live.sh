#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 1 ]] || { echo 'Usage: bash macOS/scripts/test-ai-live.sh /absolute/path/to/ignored/.env' >&2; exit 1; }
mkdir -p build/swift-module-cache
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/AIDiagnostics.swift macOS/Sources/AISettings.swift macOS/Sources/AIChatCompletions.swift \
  macOS/Tests/AILiveConfiguration.swift macOS/Tests/AILiveTests.swift -framework Security -o build/ai-live-tests
build/ai-live-tests "$1"
