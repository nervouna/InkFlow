#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:-$PWD/build/InkFlow.app}"
mode="${2:---build}"
[[ "$mode" == --build || "$mode" == --verify ]] || exit 2
source macOS/scripts/swift-common.sh
mkdir -p build/packaged-cache-objects build/swift-module-cache
xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=26.0 -I build/deps/dist/include \
  -c macOS/DictionaryWorker/RimeWorker.c -o build/packaged-cache-objects/RimeWorker.o
xcrun swiftc -swift-version 6 -warnings-as-errors -O -parse-as-library \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  -import-objc-header macOS/DictionaryWorker/RimeWorker.h \
  "${dictionary_sources[@]}" "${dictionary_update_sources[@]}" macOS/Tools/PackagedCacheTool.swift \
  build/packaged-cache-objects/RimeWorker.o "$app/Contents/Frameworks/librime.1.dylib" \
  -Xlinker -rpath -Xlinker "$app/Contents/Frameworks" -o build/packaged-cache-tool
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-packaged-cache.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
build/packaged-cache-tool "$app/Contents/Resources/Rime" "$scratch" "$mode"
