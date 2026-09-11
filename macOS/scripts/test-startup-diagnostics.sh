#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test startup-diagnostics-tests build/startup-diagnostics-tests
build/startup-diagnostics-tests
