#!/bin/bash
# Sourced from test scripts that have already changed to the repository root.
source macOS/scripts/swift-package.sh
source Core/scripts/swift-package.sh

build_swift_test() {
  local product="$1" output="$2"
  # test.sh prebuilds background units so they never compile alongside serial ones.
  if [[ "${INKFLOW_TEST_PREBUILT:-}" == 1 && -x "$output" ]]; then return 0; fi
  case "$product" in
    ai-adoption-learning-tests|ai-pronunciation-tests|dictionary-generator-tests|ranking-tests|voice-learning-coordinator-tests|voice-lexicon-tests|dictionary-store-tests)
      build_core_product "$product" "$output" debug ;;
    *) build_swift_product "$product" "$output" debug ;;
  esac
}
