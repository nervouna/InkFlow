#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache build/quality-evidence
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/QualityRecords.swift macOS/Sources/QualityStore.swift macOS/Sources/QualityRecorder.swift \
  macOS/Tests/QualityTimingTests.swift -lsqlite3 -o build/quality-timing-tests
build/quality-timing-tests
