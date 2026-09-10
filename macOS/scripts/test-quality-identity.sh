#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/QualityRecords.swift macOS/Tests/QualityIdentityTests.swift \
  -o build/quality-identity-tests
build/quality-identity-tests
