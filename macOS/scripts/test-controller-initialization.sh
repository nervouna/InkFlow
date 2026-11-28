#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
macOS/scripts/dependencies.sh
bash Core/scripts/prepare-rime.sh build/test-shared
source macOS/scripts/swift-test.sh
build_swift_test controller-initialization-tests build/controller-initialization-tests
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-initialization-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/controller-initialization-tests "$PWD/build/test-shared" "$user_dir"
