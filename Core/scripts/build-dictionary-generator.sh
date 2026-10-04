#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
binary=build/dictionary-generator
source Core/scripts/swift-package.sh
build_core_product dictionary-generator "$binary" release
