#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/dependencies.sh
bash Core/scripts/check-boundaries.sh --standalone
source Core/scripts/swift-package.sh
shared=""
skip_ai_learning=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-ai-learning) skip_ai_learning=true ;;
    --*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) [[ -z "$shared" ]] || { echo 'Usage: test.sh [SHARED] [--skip-ai-learning]' >&2; exit 2; }; shared=$1 ;;
  esac
  shift
done
bash macOS/scripts/test-dictionary-generator.sh
for product in ranking-tests ai-pronunciation-tests voice-learning-coordinator-tests voice-lexicon-tests dictionary-store-tests; do
  build_core_product "$product" "build/core-tests/$product"
  "build/core-tests/$product"
done
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ -z "$shared" ]]; then
  shared="$scratch/Rime"
  bash macOS/scripts/prepare-rime.sh "$shared"
fi
build_core_product core-engine-tests build/core-tests/core-engine-tests
for group in basic options english context custom-phrases; do
  mkdir -p "$scratch/$group"
  build/core-tests/core-engine-tests "$shared" "$scratch/$group" "--$group"
done
bash Core/scripts/test-dictionaries.sh "$shared"
if ! $skip_ai_learning; then bash macOS/scripts/test-ai-learning.sh "$shared"; fi
echo 'PASS shared core: standalone rules, generated data and real Rime compile/probe'
