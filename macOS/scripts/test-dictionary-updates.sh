#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-common.sh
[[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
common=(-swift-version 6 -warnings-as-errors -O -parse-as-library -target arm64-apple-macosx26.0 -module-cache-path build/swift-module-cache)
xcrun swiftc "${common[@]}" -module-name InkFlowDictionaryWorkerFixture "${dictionary_sources[@]}" "${dictionary_update_sources[@]}" \
  macOS/Tests/DictionaryWorkerFixture.swift -o build/dictionary-worker-fixture
xcrun swiftc "${common[@]}" -module-name InkFlowDictionaryUpdateTests "${dictionary_sources[@]}" "${dictionary_update_sources[@]}" \
  macOS/Tests/DictionaryUpdateTests.swift -o build/dictionary-update-tests
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-dictionary-updates.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
build/dictionary-update-tests "$scratch" "$PWD"
