#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 1 ]] || { echo 'Usage: bash macOS/scripts/test-ai-live.sh /absolute/path/to/ignored/.env' >&2; exit 1; }
source macOS/scripts/swift-test.sh
build_swift_test ai-live-tests build/ai-live-tests
build/ai-live-tests "$1"
