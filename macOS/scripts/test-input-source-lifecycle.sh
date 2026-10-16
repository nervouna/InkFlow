#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test input-source-lifecycle-tests build/input-source-lifecycle-tests
build/input-source-lifecycle-tests
