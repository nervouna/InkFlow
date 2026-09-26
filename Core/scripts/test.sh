#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/dependencies.sh
bash Core/scripts/check-boundaries.sh --standalone
source Core/scripts/swift-package.sh
bash macOS/scripts/test-dictionary-generator.sh
for product in ranking-tests ai-pronunciation-tests voice-learning-coordinator-tests voice-lexicon-tests dictionary-store-tests; do
  build_core_product "$product" "build/core-tests/$product"
  "build/core-tests/$product"
done
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ $# == 0 ]]; then
  shared="$scratch/Rime"
  bash macOS/scripts/prepare-rime.sh "$shared"
else
  shared="$1"
fi
build_core_product core-engine-tests build/core-tests/core-engine-tests
for group in basic options english context custom-phrases; do
  mkdir -p "$scratch/$group"
  build/core-tests/core-engine-tests "$shared" "$scratch/$group" "--$group"
done
bash Core/scripts/test-dictionaries.sh "$shared"
bash macOS/scripts/test-ai-learning.sh "$shared"
echo 'PASS shared core: standalone rules, generated data, real Rime compile/probe and learning/undo/restart'
