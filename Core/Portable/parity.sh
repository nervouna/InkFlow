#!/bin/bash
# Old/new comparison on prepared production resources: the Swift quality baseline and the
# ported engine regressions run against the Rust engine. Pass an existing resources
# directory (from prepare-resources.sh) to skip preparation.
set -euo pipefail
cd "$(dirname "$0")/../.."
resources=${1:-}
if [[ -z "$resources" ]]; then
  resources=$(bash Core/Portable/prepare-resources.sh | tee /dev/stderr | sed -n 's/^PASS production resources: //p')
fi
[[ -f "$resources/prepared/complete" ]] || { echo "Not a prepared resources directory: $resources" >&2; exit 2; }
# cargo test runs from the manifest directory.
resources=$(cd "$resources" && pwd)
export CARGO_TARGET_DIR="$PWD/build/portable/cargo"
INKFLOW_PORTABLE_RESOURCES="$resources" cargo test --locked --manifest-path Core/Portable/Cargo.toml --test parity -- --nocapture
