#!/bin/bash
# Sourced from scripts that have already changed to the repository root.
dictionary_sources=(macOS/Sources/DictionaryModels.swift macOS/Sources/DictionaryGenerator.swift)
dictionary_update_sources=(macOS/Sources/DictionaryUpdateModels.swift macOS/Sources/DictionarySourceClient.swift macOS/Sources/DictionaryStore.swift macOS/Sources/DictionaryWorkerProtocol.swift macOS/Sources/DictionaryWorkerRunner.swift)
ai_sources=(macOS/Sources/AISettings.swift macOS/Sources/AIChatCompletions.swift macOS/Sources/SmartSettingsView.swift macOS/Sources/AIContext.swift macOS/Sources/AISuggestionCoordinator.swift macOS/Sources/AISuggestionPanel.swift)
swift_sources=(macOS/Sources/QualityRecords.swift macOS/Sources/QualityStore.swift macOS/Sources/QualityRecorder.swift "${dictionary_sources[@]}" "${dictionary_update_sources[@]}" macOS/Sources/DictionaryCoordinator.swift macOS/Sources/Context.swift macOS/Sources/Engine.swift macOS/Sources/Settings.swift macOS/Sources/DictionarySettings.swift macOS/Sources/CustomPhrases.swift macOS/Sources/InputController.swift)

build_swift() {
  local output="$1"
  shift
  local objects="build/swift-objects/$(basename "$output")"
  mkdir -p build/swift-module-cache "$objects"
  xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
    -c macOS/Sources/NativeCandidates.m -o "$objects/NativeCandidates.o"
  xcrun swiftc -swift-version 6 -warnings-as-errors -g -module-name InkFlow \
    -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache \
    -I build/deps/dist/include -import-objc-header macOS/Sources/InkFlow-Bridging-Header.h \
    "${ai_sources[@]}" "$@" "$objects/NativeCandidates.o" \
    -framework AppKit -framework SwiftUI -framework InputMethodKit -framework Carbon -lsqlite3 \
    "${rime_library:-$PWD/build/deps/dist/lib/librime.1.17.0.dylib}" \
    -Xlinker -rpath -Xlinker "${rime_rpath:-$PWD/build/deps/dist/lib}" -o "$output"
}

build_swift_test() {
  local output="$1"
  shift
  local objects="build/swift-objects/$(basename "$output")"
  mkdir -p "$objects"
  xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=26.0 \
    -c macOS/Tests/NativeTestSupport.m -o "$objects/NativeTestSupport.o"
  build_swift "$output" -parse-as-library "${swift_sources[@]}" \
    -import-objc-header macOS/Tests/Tests-Bridging-Header.h \
    macOS/Tests/TestSupport.swift "$objects/NativeTestSupport.o" "$@"
}
