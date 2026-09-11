#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="${1:-$PWD/build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker}"
source macOS/scripts/swift-package.sh
build_swift_product InkFlowDictionaryWorker "$output" release
