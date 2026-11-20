#!/bin/bash
# Run on the target userspace with the final archives and a clean checkout.
set -euo pipefail
cd "$(dirname "$0")/../.."
version=${1:?Expected release version}
assets="$PWD/build/linux/releases/$version"
binary="InkFlow-$version-linux-aarch64"
source="InkFlow-$version-linux-source"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
(cd "$assets" && sha256sum -c SHA256SUMS-linux)
tar -xJf "$assets/$binary.tar.xz" -C "$scratch"
tar -xJf "$assets/$source.tar.xz" -C "$scratch"
python3 - "$scratch" "$binary" "$source" "$version" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root, binary, source, version = sys.argv[1:]
root = Path(root)
revision = subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip()
manifest = json.loads((root / binary / 'package.json').read_text())
assert sorted(p.name for p in root.iterdir()) == sorted([binary, source])
assert manifest['version'] == version and manifest['revision'] == revision
assert manifest['architecture'] == 'aarch64'
assert not (root / binary / 'share/inkflow/SOURCE').exists()
assert source + '.tar.xz' in (root / binary / 'share/inkflow/SOURCE.txt').read_text()
assert revision in (root / source / 'REBUILD.txt').read_text()
assert (root / source / 'inkflow.tar').stat().st_size > 0
PY
python3 -B Linux/scripts/test_package.py "$scratch/$binary"
