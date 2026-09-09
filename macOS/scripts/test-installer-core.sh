#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/installer-core
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
  -module-cache-path build/installer-core/module-cache \
  macOS/Shared/InputSourceManager.swift \
  macOS/Installer/Installer*.swift macOS/Tests/InstallerCoreTests.swift \
  -framework Foundation -framework AppKit -framework Carbon \
  -o build/installer-core/installer-tests
build/installer-core/installer-tests
