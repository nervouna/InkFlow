#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# -eq 0 || ( $# -eq 1 && "$1" == --native ) ]] || { echo 'Usage: test-serving-startup.sh [--native]' >&2; exit 2; }
mkdir -p build
run_dir=$(mktemp -d "$PWD/build/serving-startup-run.XXXXXX")
echo "Startup evidence: $run_dir/run.log"
source macOS/scripts/swift-test.sh
build_swift_test serving-startup-tests build/serving-startup-tests 2>&1 | tee "$run_dir/compile.log"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-serving-startup.XXXXXX")
trap 'chmod -R u+w "$scratch"; rm -rf "$scratch"' EXIT
echo "Temporary user root: $scratch"
binary="$PWD/build/serving-startup-tests"
if [[ "${1:-}" == --native ]]; then
  harness="$run_dir/ServingStartupHarness.app"
  mkdir -p "$harness/Contents/MacOS"
  cp macOS/Tests/ServingStartupHarness.plist "$harness/Contents/Info.plist"
  cp "$binary" "$harness/Contents/MacOS/ServingStartupHarness"
  binary="$harness/Contents/MacOS/ServingStartupHarness"
fi
"$binary" "$scratch" "$PWD/build/InkFlow.app" "$@" 2>&1 | tee "$run_dir/run.log"
rg -q '^PASS serving startup:' "$run_dir/run.log" || { echo 'Startup harness exited without final acceptance.' >&2; exit 1; }
if [[ "${1:-}" == --native ]]; then
  rg -q '^PASS native serving startup:' "$run_dir/run.log" || { echo 'Native startup acceptance marker missing.' >&2; exit 1; }
fi
