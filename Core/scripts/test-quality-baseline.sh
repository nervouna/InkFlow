#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mode=${1:-check}
[[ "$mode" == check || "$mode" == capture ]] || { echo 'Usage: test-quality-baseline.sh [check|capture] [OUTPUT]' >&2; exit 2; }
output=${2:-"$PWD/build/quality-baseline/actual.json"}
mkdir -p "$(dirname "$output")"
bash macOS/scripts/dependencies.sh
source Core/scripts/swift-package.sh
build_core_product quality-baseline build/core-tests/quality-baseline
build_core_product packaged-cache-tool build/core-tests/packaged-cache-tool
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-quality-baseline.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bash macOS/scripts/prepare-rime.sh "$scratch/Rime"
build/core-tests/packaged-cache-tool "$scratch/Rime" "$scratch/compile" --compile
baseline="$PWD/Core/Fixtures/QualityBaseline/baseline.json"
[[ "$mode" != capture ]] || baseline=-
revision=$(git rev-parse HEAD)
if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then revision+=-dirty; fi
build/core-tests/quality-baseline "$PWD" "$scratch/Rime" "$scratch/users" \
  "$PWD/Core/Fixtures/QualityBaseline/corpus.json" "$output" "$revision" "$baseline"
