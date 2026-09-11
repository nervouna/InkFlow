#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build/ai-statistics-evidence
source macOS/scripts/swift-test.sh
build_swift_test ai-statistics-tests build/ai-statistics-tests
build/ai-statistics-tests
