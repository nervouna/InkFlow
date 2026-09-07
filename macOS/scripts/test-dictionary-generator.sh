#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/prepare-chinese.sh build/test-chinese
xcrun swiftc -swift-version 6 -warnings-as-errors -O -parse-as-library -module-name InkFlowDictionaryTests \
  -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
  macOS/Sources/DictionaryModels.swift macOS/Sources/DictionaryGenerator.swift \
  macOS/Tests/DictionaryGeneratorTests.swift -o build/dictionary-generator-tests
build/dictionary-generator-tests "$PWD/build/dictionary-sources" "$PWD"/build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$PWD/build/test-chinese"
