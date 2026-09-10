#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -module-cache-path build/swift-module-cache macOS/Sources/StartupDiagnostics.swift \
  macOS/Tests/StartupDiagnosticsTests.swift -o build/startup-diagnostics-tests
build/startup-diagnostics-tests
