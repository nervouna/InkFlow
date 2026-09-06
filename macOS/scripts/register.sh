#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
xcrun swiftc -swift-version 6 -warnings-as-errors -target arm64-apple-macosx26.0 \
  -module-cache-path build/swift-module-cache macOS/Tools/RegisterInputSource.swift \
  -framework Carbon -framework Foundation -o build/register-input-source
if [[ $# == 0 ]]; then set -- "$HOME/Library/Input Methods/InkFlow.app"; fi
build/register-input-source "$@"
