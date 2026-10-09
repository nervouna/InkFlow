#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash Core/scripts/resource-dependencies.sh
bash Core/scripts/prepare-chinese.sh --sources-only
python3 Core/Portable/build-native.py
mkdir -p build/portable
work=$(mktemp -d "$PWD/build/portable/resources.XXXXXX")
bash Core/scripts/prepare-rime.sh "$work/shared"
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
cargo run --locked --release --manifest-path Core/Portable/Cargo.toml --bin prepare-resources -- \
  "$work/shared" "$work/prepared"
python3 - "$work" <<'PY'
import hashlib
import json
from pathlib import Path
import platform
import sys
root = Path(sys.argv[1])
def hashes(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(directory.rglob('*')) if p.is_file()}
report = {'platform': platform.system(), 'architecture': platform.machine(),
          'nativeBuild': json.loads(Path('build/portable/native-build.json').read_text()),
          'sourceSHA256': hashes(root / 'shared'),
          'cacheSHA256': hashes(root / 'prepared/cache'),
          'manifest': json.loads((root / 'shared/dictionary-manifest.json').read_text())}
(root / 'resources.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(f'PASS production resources: {root}')
PY
if [[ $# -eq 1 ]]; then cp "$work/resources.json" "$1/resources.json"; fi
