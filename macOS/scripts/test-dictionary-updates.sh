#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ $# == 0 || ( $# == 1 && ( $1 == --source || $1 == --store || $1 == --worker ) ) ]] || {
  echo 'Usage: test-dictionary-updates.sh [--source | --store | --worker]' >&2; exit 2;
}
mode=${1:-all}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-dictionary-updates.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
source macOS/scripts/swift-test.sh
bash macOS/scripts/dependencies.sh
if [[ $mode == all || $mode == --worker ]]; then
  [[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
  build_swift_test dictionary-worker-fixture build/dictionary-worker-fixture
fi
if [[ $mode == all || $mode == --source ]]; then
  bash macOS/scripts/prepare-chinese.sh "$scratch/source-resources"
fi
build_swift_test dictionary-update-tests build/dictionary-update-tests
build/dictionary-update-tests "$scratch" "$PWD" "$@"
