#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export CARGO_TARGET_DIR="$PWD/build/dictionary/cargo"
cargo build --locked --release --manifest-path Core/Portable/dictionary/Cargo.toml
mkdir -p build/dictionary/include
cp -p "$CARGO_TARGET_DIR/release/inkflow-dictionary" build/dictionary-generator
# SwiftPM tracks this C include, so a changed Rust archive also relinks its callers.
identity=$(shasum -a 256 "$CARGO_TARGET_DIR/release/libinkflow_dictionary.a" | cut -d ' ' -f 1)
printf '#define INKFLOW_DICTIONARY_BUILD_ID "%s"\n' "$identity" > build/dictionary/include/build_identity.h.tmp
if ! cmp -s build/dictionary/include/build_identity.h.tmp build/dictionary/include/build_identity.h; then
  mv build/dictionary/include/build_identity.h.tmp build/dictionary/include/build_identity.h
else
  rm build/dictionary/include/build_identity.h.tmp
fi
