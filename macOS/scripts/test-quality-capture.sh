#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
macOS/scripts/dependencies.sh
bash macOS/scripts/prepare-rime.sh build/test-shared
source macOS/scripts/swift-test.sh
mkdir -p build/quality-evidence
build_swift_test quality-capture-tests build/quality-capture-tests
build/quality-capture-tests "$PWD/build/test-shared" "$PWD/build/quality-evidence"
