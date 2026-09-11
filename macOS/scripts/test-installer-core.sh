#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test installer-core-tests build/installer-core/installer-tests
build/installer-core/installer-tests
