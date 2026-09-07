#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${1:-$PWD/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker}"
mkdir -p "$(dirname "$output")" build/swift-module-cache build/worker-objects
xcrun clang -Wall -Wextra -Werror -mmacosx-version-min=26.0 -I build/deps/dist/include \
  -c macOS/DictionaryWorker/RimeWorker.c -o build/worker-objects/RimeWorker.o
xcrun swiftc -swift-version 6 -warnings-as-errors -O -module-name InkFlowDictionaryWorker \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  -import-objc-header macOS/DictionaryWorker/RimeWorker.h \
  macOS/Sources/InputPreferences.swift macOS/Sources/DictionaryModels.swift macOS/Sources/DictionaryGenerator.swift \
  macOS/Sources/DictionaryUpdateModels.swift macOS/Sources/DictionaryStore.swift \
  macOS/Sources/DictionaryWorkerProtocol.swift macOS/DictionaryWorker/main.swift \
  build/worker-objects/RimeWorker.o build/deps/dist/lib/librime.1.17.0.dylib \
  -Xlinker -rpath -Xlinker '@executable_path/../Frameworks' -o "$output"
