#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:-$PWD/build/InkFlow.app}"
mode="${2:---build}"
[[ "$mode" == --build || "$mode" == --verify ]] || exit 2
source macOS/scripts/swift-package.sh
build_swift_product packaged-cache-tool build/packaged-cache-tool release
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-packaged-cache.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
build/packaged-cache-tool "$app/Contents/Resources/Rime" "$scratch" "$mode"
