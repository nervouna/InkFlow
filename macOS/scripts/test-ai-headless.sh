#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
prebuilt=false
if [[ $# -gt 0 && $1 == --prebuilt ]]; then
  [[ "${INKFLOW_SWIFT_TEST_PREBUILT:-}" == 1 ]] || {
    echo 'The --prebuilt mode is reserved for the prepared full-suite runner.' >&2
    exit 2
  }
  prebuilt=true
  shift
fi
[[ $# == 0 || ( $# == 1 && $1 == --delayed-visibility ) || ( $# == 2 && $1 == --live && $2 == /* ) ]] || {
  echo 'Usage: test-ai-headless.sh [--prebuilt] [--delayed-visibility | --live /absolute/path/to/ignored/.env]' >&2; exit 1;
}
[[ -f build/test-shared/inkflow_pinyin.schema.yaml ]] || { echo 'Run test.sh first to prepare test-shared.' >&2; exit 1; }
source macOS/scripts/swift-test.sh
if $prebuilt; then
  [[ -x build/ai-headless-tests ]] || { echo 'Missing prebuilt ai-headless-tests product.' >&2; exit 1; }
else
  build_swift_test ai-headless-tests build/ai-headless-tests
fi
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-ai-headless.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
result_log="$user_dir/ai-headless-check.log"
build/ai-headless-tests "$PWD/build/test-shared" "$user_dir" "$@" | tee "$result_log"
rg -q '^PASS headless AI (pipeline|delayed visibility)' "$result_log" || {
  echo 'Headless harness exited before its final acceptance result.' >&2; exit 1;
}
