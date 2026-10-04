#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../../.."
root=$PWD
report=${1:-"$root/build/dictionary-parity/report"}
mkdir -p "$report"
report=$(cd "$report" && pwd)
export CARGO_TARGET_DIR="$root/build/dictionary/cargo"
fixtures="$root/Core/Portable/dictionary/fixtures"
reference="$fixtures"
comparison=()
bridge=()
if [[ $(uname -s) == Darwin ]]; then
  bash macOS/scripts/test-dictionary-generator.sh
  build/dictionary-generator-tests --export-reference "$fixtures/cases.json" "$report"
  reference="$report"
  comparison=(--swift "$root/build/test-chinese-reference")
fi
export INKFLOW_DICTIONARY_REFERENCE="$reference"
cargo test --locked --release --manifest-path Core/Portable/dictionary/Cargo.toml -- --nocapture
cargo build --locked --release --manifest-path Core/Portable/dictionary/Cargo.toml
include="$root/Core/Portable/dictionary/include"
archive="$CARGO_TARGET_DIR/release/libinkflow_dictionary.a"
libs=(-ldl -lpthread -lm)
if [[ $(uname -s) == Darwin ]]; then
  libs=(-lresolv -liconv)
  swiftc -O -warnings-as-errors -I "$include" \
    Core/Portable/dictionary/tests/NativeGenerator.swift "$archive" "${libs[@]}" \
    -o "$CARGO_TARGET_DIR/release/swift-native-generator"
  bridge=(--bridge "$CARGO_TARGET_DIR/release/swift-native-generator")
fi
cc -std=c11 -Wall -Wextra -Werror -I "$include" \
  Core/Portable/dictionary/tests/native.c "$archive" "${libs[@]}" \
  -o "$CARGO_TARGET_DIR/release/dictionary-native-test"
"$CARGO_TARGET_DIR/release/dictionary-native-test"
python3 Core/Portable/dictionary/verify.py --binary "$CARGO_TARGET_DIR/release/inkflow-dictionary" \
  --catalog "$reference/catalog.json" --report "$report" "${comparison[@]}" "${bridge[@]}"
