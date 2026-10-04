#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
python3 Core/Portable/build-native.py
cargo test --locked --manifest-path Core/Portable/Cargo.toml -- --nocapture
if [[ $# -eq 1 ]]; then
  cp build/portable/native-build.json "$1/native-build.json"
fi
