#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/test-timing.sh
stage_started=$(inkflow_test_timing_now)
bash macOS/scripts/dependencies.sh
bash Core/scripts/check-boundaries.sh --standalone
inkflow_test_timing_report shared-core dependencies-boundaries "$stage_started"
source Core/scripts/swift-package.sh
shared=""
skip_covered_units=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-covered-units) skip_covered_units=true ;;
    --*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "$shared" ]] || { echo 'Usage: test.sh [SHARED] [--skip-covered-units]' >&2; exit 2; }; shared=$1 ;;
  esac
  shift
done
if ! $skip_covered_units; then bash macOS/scripts/test-dictionary-generator.sh; fi
# The standalone package owns compilation of all its test products. During the
# embedded full suite, canonical macOS units own the duplicated expensive
# behavior runs, while Core-only ranking and voice coordination still execute.
products=(ranking-tests ai-pronunciation-tests voice-learning-coordinator-tests voice-lexicon-tests dictionary-store-tests)
stage_started=$(inkflow_test_timing_now)
for product in "${products[@]}"; do
  build_core_product "$product" "build/core-tests/$product"
  if ! $skip_covered_units || [[ $product == ranking-tests || $product == voice-learning-coordinator-tests ]]; then
    "build/core-tests/$product"
  fi
done
inkflow_test_timing_report shared-core unit-products "$stage_started"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
stage_started=$(inkflow_test_timing_now)
if [[ -z "$shared" ]]; then
  shared="$scratch/Rime"
  bash macOS/scripts/prepare-rime.sh "$shared"
fi
inkflow_test_timing_report shared-core resources "$stage_started"
stage_started=$(inkflow_test_timing_now)
build_core_product core-engine-tests build/core-tests/core-engine-tests
inkflow_test_timing_report shared-core engine-build "$stage_started"
if $skip_covered_units; then
  stage_started=$(inkflow_test_timing_now)
  for product in core-dictionary-tests dictionary-preparation-fixture packaged-cache-tool; do
    build_core_product "$product" "build/core-tests/$product"
  done
  inkflow_test_timing_report shared-core native-host-build "$stage_started"
fi
if ! $skip_covered_units; then
  bash Core/scripts/test-quality-baseline.sh
  stage_started=$(inkflow_test_timing_now)
  for group in basic options english context custom-phrases; do
    mkdir -p "$scratch/$group"
    build/core-tests/core-engine-tests "$shared" "$scratch/$group" "--$group"
  done
  inkflow_test_timing_report shared-core engine-regression "$stage_started"
  stage_started=$(inkflow_test_timing_now)
  bash Core/scripts/test-dictionaries.sh "$shared"
  inkflow_test_timing_report shared-core dictionary-contract "$stage_started"
fi
if ! $skip_covered_units; then
  stage_started=$(inkflow_test_timing_now)
  bash macOS/scripts/test-ai-learning.sh "$shared"
  inkflow_test_timing_report shared-core ai-learning "$stage_started"
fi
if $skip_covered_units; then
  echo 'PASS shared core: all standalone targets compile; duplicate assertions delegated'
else
  echo 'PASS shared core: standalone rules, generated data and real Rime compile/probe'
fi
