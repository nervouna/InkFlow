#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/quality-evidence
source macOS/scripts/swift-test.sh
build_swift_test quality-store-tests build/quality-store-tests
build/quality-store-tests
