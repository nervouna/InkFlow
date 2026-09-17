#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test local-diagnostics-tests build/local-diagnostics-tests
build/local-diagnostics-tests
