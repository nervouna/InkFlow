#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
python3 Core/Portable/build-native.py
if [[ $(uname -s) == Darwin ]]; then
  bash Core/Portable/ranking-reference.sh build/portable
  python3 - <<'PY'
import json
from pathlib import Path
assert json.loads(Path('build/portable/ranking-reference.json').read_text()) == json.loads(
    Path('Core/Portable/fixtures/ranking-reference.json').read_text())
print('PASS fresh Swift ranking reference matches recorded cases')
PY
fi
cargo test --locked --manifest-path Core/Portable/Cargo.toml -- --nocapture
bash Core/Portable/abi.sh
if [[ $# -eq 1 ]]; then
  cp build/portable/native-build.json "$1/native-build.json"
  if [[ $(uname -s) == Darwin ]]; then cp build/portable/ranking-reference.json "$1/ranking-reference.json"; fi
fi
