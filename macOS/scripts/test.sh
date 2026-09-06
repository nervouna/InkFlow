#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/test-quality-store.sh
bash macOS/scripts/test-quality-metadata.sh
macOS/scripts/dependencies.sh
bash macOS/scripts/test-prepare-rime.sh
bash macOS/scripts/prepare-rime.sh build/test-shared
source macOS/scripts/swift-common.sh
build_swift_test build/deployment-tests macOS/Tests/DeploymentTests.swift
build/deployment-tests "$PWD/build/test-shared" "$PWD"/build/deps/rime-easy-en-*/easy_en.dict.yaml
build_swift_test build/engine-tests macOS/Tests/EngineTests.swift
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/engine-tests "$PWD/build/test-shared" "$user_dir"
build_swift_test build/controller-tests macOS/Tests/ControllerTests.swift
build/controller-tests "$PWD/build/test-shared" "$user_dir"
build_swift_test build/settings-tests macOS/Tests/SettingsTests.swift
build/settings-tests
