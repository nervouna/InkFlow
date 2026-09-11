#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Requires a previously built app/worker. Uses only a synthetic temporary user root, never the user's data.
source macOS/scripts/swift-test.sh
[[ -x build/InkFlow.app/Contents/MacOS/InkFlowDictionaryWorker ]] || { echo 'Run build.sh first.' >&2; exit 1; }
build_swift_test dictionary-activation-tests build/dictionary-activation-tests
activation_root=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-activation-tests.XXXXXX")
trap 'rm -rf "$activation_root"' EXIT
build/dictionary-activation-tests "$activation_root" "$PWD"
