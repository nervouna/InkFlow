#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# Requires a logged-in macOS GUI session; deliberately separate from headless logic tests.
macOS/scripts/dependencies.sh
mkdir -p build/test-shared
cp schemas/*.yaml build/test-shared/
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml build/test-shared/
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -I macOS/Sources -I build/deps/dist/include macOS/Sources/Engine.m macOS/Sources/Settings.m macOS/Sources/InputController.m macOS/Tests/ControllerInitializationTests.m -framework AppKit -framework InputMethodKit -framework Carbon -L build/deps/dist/lib -lrime -Wl,-rpath,"$PWD/build/deps/dist/lib" -o build/controller-initialization-tests
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-initialization-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/controller-initialization-tests "$PWD/build/test-shared" "$user_dir"
