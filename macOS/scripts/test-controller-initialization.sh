#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Requires a logged-in macOS GUI session; deliberately separate from headless logic tests.
macOS/scripts/dependencies.sh
mkdir -p build/test-shared
cp schemas/*.yaml build/test-shared/
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml build/test-shared/
source macOS/scripts/swift-common.sh
build_swift_test build/controller-initialization-tests macOS/Tests/ControllerInitializationTests.swift
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-initialization-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/controller-initialization-tests "$PWD/build/test-shared" "$user_dir"
