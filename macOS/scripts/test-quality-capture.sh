#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
if [[ $# == 0 ]]; then
  macOS/scripts/dependencies.sh
  bash macOS/scripts/prepare-rime.sh build/test-shared
  shared="$PWD/build/test-shared"
elif [[ $# == 2 && $1 == --prepared && $2 == /* ]]; then
  shared="$2"
  [[ -f "$shared/inkflow_pinyin.schema.yaml" ]] || { echo 'Missing prepared schema' >&2; exit 1; }
else
  echo 'Usage: test-quality-capture.sh [--prepared /absolute/shared/path]' >&2; exit 2
fi
source macOS/scripts/swift-test.sh
mkdir -p build/quality-evidence
build_swift_test quality-capture-tests build/quality-capture-tests
build/quality-capture-tests "$shared" "$PWD/build/quality-evidence"
