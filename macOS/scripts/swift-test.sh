#!/bin/bash
# Sourced from test scripts that have already changed to the repository root.
source macOS/scripts/swift-package.sh
source Core/scripts/swift-package.sh

build_swift_test() {
  local product="$1" output="$2"
  if [[ "${INKFLOW_SWIFT_TEST_PREBUILT:-}" == 1 ]]; then
    [[ -x "$output" ]] || { echo "Missing prebuilt Swift test product: $output" >&2; return 1; }
    return 0
  fi
  case "$product" in
    ai-adoption-learning-tests|ai-pronunciation-tests|dictionary-generator-tests|ranking-tests|voice-learning-coordinator-tests|voice-lexicon-tests|dictionary-store-tests)
      build_core_product "$product" "$output" debug ;;
    *) build_swift_product "$product" "$output" debug ;;
  esac
}
