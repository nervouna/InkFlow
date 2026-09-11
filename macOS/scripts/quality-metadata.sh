#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:-$PWD/build/InkFlow.app}"
source macOS/scripts/swift-package.sh
build_swift_product quality-build-metadata build/quality-build-metadata debug
if [[ "${2:-}" == --verify ]]; then
  build/quality-build-metadata "$PWD" "$app" --verify
else
  build/quality-build-metadata "$PWD" "$app"
fi
