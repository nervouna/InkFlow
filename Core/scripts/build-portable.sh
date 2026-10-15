#!/bin/bash
# Build the portable core that macOS links: the source-pinned native dependencies and the
# release libinkflow_rime.a, all under build/portable. Safe to rerun; CMake, b2 and Cargo
# only rebuild what changed.
set -euo pipefail
cd "$(dirname "$0")/../.."
sha256=(shasum -a 256)
if command -v sha256sum >/dev/null; then sha256=(sha256sum); fi
# Same value build-native.py reads for the native libraries: the app's minimum macOS.
export MACOSX_DEPLOYMENT_TARGET=$(plutil -extract LSMinimumSystemVersion raw -o - macOS/Info.plist)
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
python3 Core/Portable/build-native.py
cargo build --locked --release --manifest-path Core/Portable/Cargo.toml
mkdir -p build/portable/include
# SwiftPM tracks this C include, so a changed Rust archive or librime also relinks its callers.
identity=$("${sha256[@]}" "$CARGO_TARGET_DIR/release/libinkflow_rime.a" build/portable/prefix/lib/librime.1.dylib \
  | cut -d ' ' -f 1 | "${sha256[@]}" | cut -d ' ' -f 1)
printf '#define INKFLOW_PORTABLE_BUILD_ID "%s"\n' "$identity" > build/portable/include/build_identity.h.tmp
if ! cmp -s build/portable/include/build_identity.h.tmp build/portable/include/build_identity.h; then
  mv build/portable/include/build_identity.h.tmp build/portable/include/build_identity.h
else
  rm build/portable/include/build_identity.h.tmp
fi
echo "PASS portable core: $CARGO_TARGET_DIR/release/libinkflow_rime.a (macOS $MACOSX_DEPLOYMENT_TARGET)"
