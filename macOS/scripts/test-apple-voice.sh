#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test apple-voice-tests build/apple-voice-tests
build/apple-voice-tests
