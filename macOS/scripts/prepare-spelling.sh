#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
destination=${1:?Usage: prepare-spelling.sh DESTINATION}
# The generated Chinese dictionary owns the complete syllable inventory. Rebuild
# spelling after dictionary changes, using the same generator as the update worker.
bash macOS/scripts/build-dictionary-generator.sh
build/dictionary-generator spelling "$destination/pinyin_simp.dict.yaml" "$destination"
