#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache build/quality-evidence
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/QualityRecords.swift macOS/Sources/QualityStore.swift \
  macOS/Tests/QualityStoreTests.swift -lsqlite3 -o build/quality-store-tests
build/quality-store-tests
