#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# -le 1 ]] || { echo 'Usage: test-dictionaries.sh [prepared Rime resources]' >&2; exit 2; }
bash macOS/scripts/dependencies.sh
source Core/scripts/swift-package.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core-dictionaries.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ $# == 0 ]]; then
  shared="$scratch/generated"
  bash macOS/scripts/prepare-rime.sh "$shared"
else
  shared="$1"
fi
for product in core-dictionary-tests dictionary-preparation-fixture packaged-cache-tool; do
  build_core_product "$product" "build/core-tests/$product"
done
build/core-tests/core-dictionary-tests --source "$PWD"
# Build a genuine packaged cache before any parent process starts a serving Rime runtime.
# Every runtime resource, helper copy, candidate and user database belongs to this fixture.
ditto "$shared" "$scratch/runtime/Resources/Rime"
mkdir -p "$scratch/runtime/bin" "$scratch/scenarios"
cp build/core-tests/dictionary-preparation-fixture "$scratch/runtime/bin/preparation-fixture"
build/core-tests/packaged-cache-tool "$scratch/runtime/Resources/Rime" "$scratch/compile" --compile
build/core-tests/core-dictionary-tests --activation "$PWD" "$scratch/scenarios" \
  "$scratch/runtime/Resources/Rime" "$scratch/runtime/bin/preparation-fixture" \
  "$PWD/build/deps/dist/lib/librime.1.17.0.dylib" "$PWD/build/deps/dist/lib/rime-plugins/librime-lua.dylib"
echo 'PASS independent dictionary sources, preparation, native activation, rollback and recovery'
