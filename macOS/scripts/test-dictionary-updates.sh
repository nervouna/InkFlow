#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-test.sh
[[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
build_swift_test dictionary-worker-fixture build/dictionary-worker-fixture
build_swift_test dictionary-update-tests build/dictionary-update-tests
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-dictionary-updates.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
build/dictionary-update-tests "$scratch" "$PWD"
