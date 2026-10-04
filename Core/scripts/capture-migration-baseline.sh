#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 1 ]] || { echo 'Usage: capture-migration-baseline.sh OUTPUT_DIRECTORY' >&2; exit 2; }
mkdir -p "$1"
output=$(cd "$1" && pwd)
[[ ! -e "$output/behavior.json" && ! -e "$output/performance-1.json" ]] || {
  echo 'Use a fresh evidence directory.' >&2; exit 2;
}
[[ -z "$(git status --porcelain --untracked-files=all)" ]] || {
  echo 'Baseline requires a clean, committed source revision.' >&2; exit 2;
}
bash macOS/scripts/dependencies.sh
bash Core/scripts/check-boundaries.sh --standalone
source Core/scripts/swift-package.sh
for product in quality-baseline performance-baseline packaged-cache-tool ranking-tests; do
  build_core_product "$product" "build/core-tests/$product" release
done
build/core-tests/ranking-tests
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-migration-baseline.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bash macOS/scripts/prepare-rime.sh "$scratch/Rime"
build/core-tests/packaged-cache-tool "$scratch/Rime" "$scratch/compiler" --compile
corpus="$PWD/Core/Fixtures/QualityBaseline/corpus.json"
revision=$(git rev-parse HEAD)
build/core-tests/quality-baseline "$PWD" "$scratch/Rime" "$scratch/behavior-users" \
  "$corpus" "$output/behavior.json" "$revision" "$PWD/Core/Fixtures/QualityBaseline/baseline.json"
for trial in 1 2 3 4 5; do
  build/core-tests/performance-baseline "$scratch/Rime" "$scratch/performance-user-$trial" \
    "$corpus" "$output/performance-$trial.json"
done
python3 Core/scripts/summarize-performance.py "$output"
bash macOS/scripts/test.sh engine ai-learning voice-lexicon
echo 'PASS migration baseline: behavior, performance, ranking, engine, and learning'
