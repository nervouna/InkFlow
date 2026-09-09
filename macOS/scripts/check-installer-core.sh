#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/installer-core
sources=(macOS/Shared/InputSourceManager.swift macOS/Sources/RuntimeStatus.swift macOS/Installer/Installer*.swift)
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
  -module-cache-path build/installer-core/module-cache -parse-as-library -emit-library \
  "${sources[@]}" -framework Foundation -framework AppKit -framework Carbon -framework Security \
  -o build/installer-core/libInstallerCore.dylib
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
  -module-cache-path build/installer-core/module-cache macOS/Shared/InputSourceManager.swift \
  macOS/Tools/RegisterInputSource.swift -framework Foundation -framework Carbon \
  -o build/installer-core/register-input-source
printf 'PASS production installer core and register CLI compile (not executed)\n'
