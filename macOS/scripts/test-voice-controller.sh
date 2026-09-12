#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
build_swift_test voice-controller-tests build/voice-controller-tests
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-voice-controller.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
shared=${1:-"$PWD/build/test-shared"}
if [[ ! -s "$shared/inkflow_pinyin.schema.yaml" ]]; then bash macOS/scripts/prepare-rime.sh "$shared"; fi
build/voice-controller-tests "$shared" "$scratch"
