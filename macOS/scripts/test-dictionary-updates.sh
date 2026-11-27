#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 0 || ( $# == 1 && ( $1 == --source || $1 == --store || $1 == --worker ) ) ]] || {
  echo 'Usage: test-dictionary-updates.sh [--source | --store | --worker]' >&2; exit 2;
}
mode=${1:-all}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-dictionary-updates.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
source macOS/scripts/swift-test.sh
source macOS/scripts/test-timing.sh
stage_started=$(inkflow_test_timing_now)
bash macOS/scripts/dependencies.sh
if [[ $mode == all || $mode == --worker ]]; then
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
  build_swift_test dictionary-worker-fixture build/dictionary-worker-fixture
fi
inkflow_test_timing_report dictionary-updates dependencies-worker-fixture "$stage_started"
if [[ $mode == all || $mode == --source ]]; then
  stage_started=$(inkflow_test_timing_now)
  bash macOS/scripts/prepare-chinese.sh "$scratch/source-resources"
  inkflow_test_timing_report dictionary-updates source-resources "$stage_started"
fi
stage_started=$(inkflow_test_timing_now)
build_swift_test dictionary-update-tests build/dictionary-update-tests
inkflow_test_timing_report dictionary-updates build "$stage_started"
stage_started=$(inkflow_test_timing_now)
build/dictionary-update-tests "$scratch" "$PWD" "$@"
inkflow_test_timing_report dictionary-updates execute "$stage_started"
