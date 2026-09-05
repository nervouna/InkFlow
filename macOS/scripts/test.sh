#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
macOS/scripts/dependencies.sh
mkdir -p build/test-shared
cp schemas/*.yaml build/test-shared/
cp build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml build/test-shared/
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -I macOS/Sources -I build/deps/dist/include macOS/Sources/Engine.m macOS/Tests/EngineTests.m -framework AppKit -L build/deps/dist/lib -lrime -Wl,-rpath,"$PWD/build/deps/dist/lib" -o build/engine-tests
user_dir=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-tests.XXXXXX")
trap 'rm -rf "$user_dir"' EXIT
build/engine-tests "$PWD/build/test-shared" "$user_dir"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -mmacosx-version-min=13.0 -I macOS/Sources -I build/deps/dist/include macOS/Sources/Engine.m macOS/Sources/InputController.m macOS/Tests/ControllerTests.m -framework AppKit -framework InputMethodKit -L build/deps/dist/lib -lrime -Wl,-rpath,"$PWD/build/deps/dist/lib" -o build/controller-tests
build/controller-tests "$PWD/build/test-shared" "$user_dir"
