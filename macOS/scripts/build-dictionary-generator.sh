#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/swift-module-cache
binary=build/dictionary-generator
inputs=(macOS/Sources/DictionaryModels.swift macOS/Sources/DictionaryGenerator.swift macOS/DictionaryTool/main.swift)
rebuild=false
[[ -x "$binary" ]] || rebuild=true
for input in "${inputs[@]}" "$0"; do [[ "$input" -nt "$binary" ]] && rebuild=true; done
if $rebuild; then
  xcrun swiftc -swift-version 6 -warnings-as-errors -O -module-name InkFlowDictionary \
    -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
    "${inputs[@]}" -o "$binary"
fi
