#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/prepare-chinese.sh build/test-chinese
source macOS/scripts/swift-test.sh
build_swift_test dictionary-generator-tests build/dictionary-generator-tests
build/dictionary-generator-tests "$PWD/build/dictionary-sources" "$PWD"/build/deps/rime-pinyin-simp-*/pinyin_simp.dict.yaml "$PWD/build/test-chinese"
