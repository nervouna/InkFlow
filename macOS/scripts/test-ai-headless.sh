#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 0 || ( $# == 1 && $1 == --delayed-visibility ) || ( $# == 2 && $1 == --live && $2 == /* ) ]] || {
  echo 'Usage: test-ai-headless.sh [--delayed-visibility | --live /absolute/path/to/ignored/.env]' >&2; exit 1;
}
[[ -f build/test-shared/inkflow_pinyin.schema.yaml ]] || { echo 'Run test.sh first to prepare test-shared.' >&2; exit 1; }
source macOS/scripts/swift-common.sh
build_swift_test build/ai-headless-tests macOS/Tests/AIDiagnosticTestSupport.swift macOS/Tests/AIRuntimeTestSupport.swift macOS/Tests/AILiveConfiguration.swift \
  macOS/Tests/AIHeadlessPipelineSupport.swift macOS/Tests/AIHeadlessPipelineTests.swift
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-ai-headless.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/ai-headless-tests "$PWD/build/test-shared" "$user_dir" "$@" | tee build/ai-headless-check.log
rg -q '^PASS headless AI (pipeline|delayed visibility)' build/ai-headless-check.log || {
  echo 'Headless harness exited before its final acceptance result.' >&2; exit 1;
}
