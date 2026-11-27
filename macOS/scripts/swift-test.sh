#!/bin/bash
source macOS/scripts/swift-package.sh

build_swift_test() {
  local product="$1" output="$2"
  if [[ "${INKFLOW_TEST_PREBUILT:-}" == 1 && -x "$output" ]]; then return 0; fi
  case "$product" in
    ai-adoption-learning-tests|ai-pronunciation-tests|dictionary-generator-tests|dictionary-store-tests \
      |portable-abi-tests|voice-learning-coordinator-tests|voice-lexicon-tests)
      build_core_product "$product" "$output" debug ;;
    *) build_swift_product "$product" "$output" debug ;;
  esac
}
