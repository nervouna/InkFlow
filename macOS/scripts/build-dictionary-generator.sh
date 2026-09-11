#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=build/dictionary-generator
source macOS/scripts/swift-package.sh
build_swift_product dictionary-generator "$binary" release
