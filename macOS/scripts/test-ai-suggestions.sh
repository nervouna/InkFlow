#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/AIDiagnostics.swift macOS/Sources/AISettings.swift macOS/Sources/AIChatCompletions.swift \
  macOS/Tests/AIDiagnosticTestSupport.swift macOS/Tests/AISuggestionTests.swift -framework Security -o build/ai-suggestion-tests
build/ai-suggestion-tests
