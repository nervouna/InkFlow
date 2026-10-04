#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
root=$PWD
report=${1:-"$root/build/dictionary-parity/report"}
mkdir -p "$report"
report=$(cd "$report" && pwd)
export CARGO_TARGET_DIR="$root/build/dictionary-parity/cargo"
fixtures="$root/Core/Portable/dictionary/fixtures"
reference="$fixtures"
comparison=()
if [[ $(uname -s) == Darwin ]]; then
  bash macOS/scripts/test-dictionary-generator.sh
  build/dictionary-generator-tests --export-reference "$fixtures/cases.json" "$report"
  reference="$report"
  comparison=(--swift "$root/build/test-chinese")
fi
export INKFLOW_DICTIONARY_REFERENCE="$reference"
cargo test --locked --release --manifest-path Core/Portable/dictionary/Cargo.toml -- --nocapture
cargo build --locked --release --manifest-path Core/Portable/dictionary/Cargo.toml
python3 Core/Portable/dictionary/verify.py --binary "$CARGO_TARGET_DIR/release/inkflow-dictionary" \
  --catalog "$reference/catalog.json" --report "$report" "${comparison[@]}"
