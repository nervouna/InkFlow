#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
shared=""
preparation_only=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --preparation-only) preparation_only=true ;;
    --*) echo 'Usage: test-dictionaries.sh [prepared Rime resources] [--preparation-only]' >&2; exit 2 ;;
    *) [[ -z "$shared" ]] || { echo 'Usage: test-dictionaries.sh [prepared Rime resources] [--preparation-only]' >&2; exit 2; }; shared=$1 ;;
  esac
  shift
done
source macOS/scripts/test-timing.sh
stage_started=$(inkflow_test_timing_now)
bash macOS/scripts/dependencies.sh
source Core/scripts/swift-package.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core-dictionaries.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ -z "$shared" ]]; then
  shared="$scratch/generated"
  bash macOS/scripts/prepare-rime.sh "$shared"
fi
inkflow_test_timing_report core-dictionaries prepare "$stage_started"
stage_started=$(inkflow_test_timing_now)
for product in core-dictionary-tests dictionary-preparation-fixture packaged-cache-tool; do
  build_core_product "$product" "build/core-tests/$product"
done
inkflow_test_timing_report core-dictionaries build "$stage_started"
if ! $preparation_only; then
  stage_started=$(inkflow_test_timing_now)
  build/core-tests/core-dictionary-tests --source "$PWD"
  inkflow_test_timing_report core-dictionaries source "$stage_started"
fi
# Build a genuine packaged cache before any parent process starts a serving Rime runtime.
# Every runtime resource, helper copy, candidate and user database belongs to this fixture.
ditto "$shared" "$scratch/runtime/Resources/Rime"
mkdir -p "$scratch/runtime/bin" "$scratch/scenarios"
cp build/core-tests/dictionary-preparation-fixture "$scratch/runtime/bin/preparation-fixture"
stage_started=$(inkflow_test_timing_now)
build/core-tests/packaged-cache-tool "$scratch/runtime/Resources/Rime" "$scratch/compile" --compile
inkflow_test_timing_report core-dictionaries packaged-cache "$stage_started"
stage_started=$(inkflow_test_timing_now)
if $preparation_only; then mode=--preparation; else mode=--activation; fi
build/core-tests/core-dictionary-tests "$mode" "$PWD" "$scratch/scenarios" \
  "$scratch/runtime/Resources/Rime" "$scratch/runtime/bin/preparation-fixture" \
  "$PWD/build/deps/dist/lib/librime.1.17.0.dylib" "$PWD/build/deps/dist/lib/rime-plugins/librime-lua.dylib"
if $preparation_only; then stage=native-preparation; else stage=activation; fi
inkflow_test_timing_report core-dictionaries "$stage" "$stage_started"
if $preparation_only; then
  echo 'PASS independent native dictionary preparation host regression'
else
  echo 'PASS independent dictionary sources, preparation, native activation, rollback and recovery'
fi
