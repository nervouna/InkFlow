#!/bin/bash
# Record the Swift engine's quality evidence for fixtures/quality-evidence-cases.json: what
# IFEngine.qualitySnapshot() reports for each step, which the Rust engine is compared with in
# tests/parity.rs. macOS only. Needs the Swift dependencies (macOS/scripts/dependencies.sh) and a
# prepared resources directory (prepare-resources.sh). The recording stays as the permanent
# reference. Since the macOS cutover (#81) IFEngine is a facade over the Rust core, so this
# reproduces the recording only at a revision before it; run later, it records the Rust core.
#   quality-evidence-reference.sh RESOURCES [OUTPUT]
set -euo pipefail
cd "$(dirname "$0")/../.."
resources=${1:?usage: quality-evidence-reference.sh RESOURCES [OUTPUT]}
[[ -f "$resources/prepared/complete" ]] || { echo "Not a prepared resources directory: $resources" >&2; exit 2; }
resources=$(cd "$resources" && pwd)
output=${2:-"$PWD/Core/Portable/fixtures/quality-evidence.json"}
bash macOS/scripts/dependencies.sh
bash Core/scripts/build-dictionary-generator.sh
# Core/Package.swift is not edited: the recorder is one more target of a copy of it that links the
# same sources, because the engine API it reads is package-internal.
package="$PWD/build/portable/quality-evidence-package"
rm -rf "$package"
mkdir -p "$package"
for directory in Sources Tests Tools; do ln -s "$PWD/Core/$directory" "$package/$directory"; done
ln -s "$PWD/Core/Portable" "$package/Portable"
python3 - "$PWD" "$package/Package.swift" <<'PY'
import sys
from pathlib import Path
repository, output = sys.argv[1:]
manifest = Path(repository, 'Core/Package.swift').read_text()
location = 'URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()'
assert location in manifest and '    targets: [\n' in manifest
manifest = manifest.replace(location, f'URL(fileURLWithPath: "{repository}")')
manifest = manifest.replace('    targets: [\n', '''    targets: [
        .executableTarget(name: "QualityEvidenceReference", dependencies: ["InkFlowDomain", "InkFlowRime"],
                          path: "Portable", sources: ["tests/QualityEvidenceReference.swift"], linkerSettings: portableRuntime),
''', 1)
Path(output).write_text(manifest)
PY
scratch="$PWD/build/portable/quality-evidence-swiftpm"
args=(--package-path "$package" --disable-sandbox --scratch-path "$scratch" --cache-path "$scratch/cache"
  --config-path "$scratch/config" --security-path "$scratch/security" --triple arm64-apple-macosx26.0
  --configuration debug --product QualityEvidenceReference -Xcc "-I$PWD/build/deps/dist/include")
export CLANG_MODULE_CACHE_PATH="$scratch/module-cache" SWIFTPM_MODULECACHE_OVERRIDE="$scratch/module-cache"
xcrun swift build "${args[@]}"
binary="$(xcrun swift build "${args[@]}" --show-bin-path)/QualityEvidenceReference"
work=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-quality-evidence.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The revision names the Swift engine and schema sources that produced the recording.
revision=$(git rev-parse HEAD)
if [[ -n "$(git status --porcelain --untracked-files=normal -- Core/Sources Core/Package.swift schemas)" ]]; then revision+=-dirty; fi
"$binary" "$resources/shared" "$work/user" Core/Portable/fixtures/quality-evidence-cases.json "$output" "$revision"
