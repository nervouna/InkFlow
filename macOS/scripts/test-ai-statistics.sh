#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache build/ai-statistics-evidence
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/AIStatistics.swift macOS/Sources/AIStatisticsStore.swift \
  macOS/Tests/AIStatisticsTestSupport.swift macOS/Tests/AIStatisticsTests.swift -lsqlite3 -o build/ai-statistics-tests
build/ai-statistics-tests
