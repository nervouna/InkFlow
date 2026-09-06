#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:-$PWD/build/InkFlow.app}"
mkdir -p build/swift-module-cache
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/QualityRecords.swift macOS/Tools/QualityBuildMetadata.swift \
  -o build/quality-build-metadata
if [[ "${2:-}" == --verify ]]; then
  build/quality-build-metadata "$PWD" "$app" --verify
else
  build/quality-build-metadata "$PWD" "$app"
fi
