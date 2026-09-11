#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test ai-credential-tests build/ai-credential-tests
build/ai-credential-tests
