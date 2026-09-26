#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core-boundaries.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
export CLANG_MODULE_CACHE_PATH="$PWD/build/core-swiftpm/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
args=(--disable-sandbox --scratch-path "$PWD/build/core-boundary-swiftpm" --cache-path "$PWD/build/core-swiftpm/cache"
  --config-path "$PWD/build/core-swiftpm/config" --security-path "$PWD/build/core-swiftpm/security")
# dump-package evaluates declarations only; it does not resolve the root's external dependencies.
if [[ "${1:-}" != --standalone ]]; then
  xcrun swift package "${args[@]}" dump-package > "$scratch/root.json"
else
  printf 'null\n' > "$scratch/root.json"
fi
xcrun swift package --package-path Core "${args[@]}" dump-package > "$scratch/core.json"
python3 - "$PWD" "$scratch/root.json" "$scratch/core.json" <<'PY'
import json
from pathlib import Path
import re
import sys
root = Path(sys.argv[1])
outer, core = (json.loads(Path(path).read_text()) for path in sys.argv[2:])
assert not core['dependencies'], 'Standalone core must not resolve platform packages'
outer_targets = {item['name']: item for item in outer['targets']} if outer else {}
core_targets = {item['name']: item for item in core['targets']}
required = {'InkFlowDomain', 'InkFlowRime', 'CRime', 'InkFlowRimeWorker', 'DictionaryGeneratorTool', 'PackagedCacheTool'}
assert required <= core_targets.keys()
if outer:
    assert required <= outer_targets.keys()
for name in outer_targets.keys() & core_targets.keys():
    a, b = outer_targets[name], core_targets[name]
    for field in ['dependencies', 'settings', 'publicHeadersPath', 'type', 'packageAccess', 'resources', 'sources', 'exclude']:
        assert a.get(field) == b.get(field), f'{name}: manifest drift in {field}'
    a_path = root / a.get('path', 'Sources/' + name)
    b_path = root / 'Core' / b.get('path', 'Sources/' + name)
    assert a_path.resolve() == b_path.resolve(), f'{name}: different production/test sources'
for target in core_targets.values():
    for dependency in target['dependencies']:
        name = dependency.get('byName', dependency.get('target', [None]))[0]
        assert name in core_targets, f"{target['name']}: external/platform dependency {name}"
for path in (root / 'Core').rglob('*.swift'):
    text = path.read_text()
    assert not re.search(r'\bimport\s+(AppKit|SwiftUI|InputMethodKit|UIKit|Carbon|Sparkle)\b', text), path
    if 'Sources' in path.parts:
        assert '@testable' not in text and '@_spi' not in text, path
        assert not re.search(r'\bProcess\s*\(', text), path
print('PASS shared boundary: independent dependency graph, no platform UI imports or access bypass' + ('; root/core source and settings parity' if outer else ''))
PY
