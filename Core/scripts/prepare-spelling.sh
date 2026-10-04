#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-spelling.sh DESTINATION}
# The generated Chinese dictionary owns the complete syllable inventory. Rebuild
# spelling and the context-ranking index after dictionary changes, using the same
# generator as the update worker.
bash Core/scripts/build-dictionary-generator.sh
staging=$(mktemp -d build/.spelling.XXXXXX)
trap 'rm -rf "$staging"' EXIT
build/dictionary-generator spelling "$destination/pinyin_simp.dict.yaml" "$staging/generated"
cp "$staging/generated/"*.schema.yaml "$destination/"
