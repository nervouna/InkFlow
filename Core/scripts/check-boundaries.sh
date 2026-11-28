#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-core-boundaries.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
boundary_fail() { echo "FAIL boundary: $1" >&2; exit 1; }
manifest=macOS/Quality/ranking-resources.txt
for bundled in schemas/*.yaml schemas/lua/*.lua schemas/opencc/*; do
  grep -qxF "Rime/${bundled#schemas/}" "$manifest" || boundary_fail "$bundled is bundled but missing from $manifest"
done
memory_uses=$(grep -nE 'Memory\(' schemas/lua/*.lua | grep -v '^schemas/lua/inkflow_channel.lua:' \
  | grep -vF 'env.memory = Memory(' || true)
[[ -z "$memory_uses" ]] || boundary_fail "open a short-lived Memory through channel.with_memory: $memory_uses"
units=$(sed -n '/^all_units=(/,/)$/p' macOS/scripts/test.sh | sed 's/^all_units=(//; s/)$//')
manual=$(grep '^manual_harnesses=(' macOS/scripts/test.sh | sed 's/^manual_harnesses=(//; s/)$//')
registered=" "
pending=$(grep -o 'test-[a-z0-9-]*\.sh' macOS/scripts/test.sh || true)
for unit in $units $manual; do
  pending+=" test-$unit.sh"
done
while [[ -n "${pending// /}" ]]; do
  next=""
  for script in $pending; do
    [[ "$registered" != *" $script "* ]] || continue
    registered+="$script "
    [[ ! -f "macOS/scripts/$script" ]] || next+=" $(grep -o 'test-[a-z0-9-]*\.sh' "macOS/scripts/$script" || true)"
  done
  pending=$next
done
for path in macOS/scripts/test-*.sh; do
  [[ "$registered" == *" ${path##*/} "* ]] || boundary_fail "${path##*/} is in no test.sh unit or manual_harnesses"
done
for name in $manual; do
  [[ -f "macOS/scripts/test-$name.sh" ]] || boundary_fail "manual_harnesses names missing script test-$name.sh"
done
swift=(swift); ! command -v xcrun >/dev/null || swift=(xcrun swift)
export CLANG_MODULE_CACHE_PATH="$PWD/build/core-swiftpm/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
args=(--disable-sandbox --scratch-path "$PWD/build/core-boundary-swiftpm" --cache-path "$PWD/build/core-swiftpm/cache"
  --config-path "$PWD/build/core-swiftpm/config" --security-path "$PWD/build/core-swiftpm/security")
if [[ "${1:-}" != --standalone ]]; then
  "${swift[@]}" package "${args[@]}" dump-package > "$scratch/root.json"
else
  printf 'null\n' > "$scratch/root.json"
fi
"${swift[@]}" package --package-path Core "${args[@]}" dump-package > "$scratch/core.json"
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
required = {'InkFlowDomain', 'InkFlowRime'}
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
for name, target in outer_targets.items():
    path = target.get('path', '')
    if path.startswith('Core/'):
        assert name in core_targets, f'{name}: declare Core targets in Core/Package.swift'
    else:
        assert not target.get('sources') and not target.get('exclude'), f'{name}: list no sources; use a directory'
portable = {('Core', 'Sources', 'InkFlowRime'), ('Core', 'Tests', 'PortableABITests')}
for path in [*(root / 'Core').rglob('*.swift'), *(root / 'macOS').rglob('*.swift')]:
    text = path.read_text()
    assert '#if SWIFT_PACKAGE' not in text, path
    relative = path.relative_to(root).parts
    if re.search(r'^import\s+InkFlowPortable\b', text, re.M):
        assert relative[:3] in portable, f'{path}: reach the portable core through InkFlowRime'
print('PASS shared boundary: independent dependency graph, no platform UI imports or access bypass' + ('; root/core source and settings parity' if outer else ''))
PY
