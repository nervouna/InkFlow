#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
app="${1:-$PWD/build/InkFlow.app}"
source macOS/scripts/swift-package.sh
if [[ "${INKFLOW_SKIP_SWIFTPM_BUILD:-0}" != 1 ]]; then
  build_swift_product quality-build-metadata build/quality-build-metadata debug
fi
[[ -x build/quality-build-metadata ]] || { echo 'Missing quality metadata tool; run build.sh first.' >&2; exit 1; }
if [[ "${2:-}" == --verify || "${2:-}" == --verify-signed ]]; then
  build/quality-build-metadata "$PWD" "$app" "$2"
else
  [[ $# -le 1 ]] || { echo 'Usage: quality-metadata.sh [app] [--verify|--verify-signed]' >&2; exit 2; }
  build/quality-build-metadata "$PWD" "$app"
fi
