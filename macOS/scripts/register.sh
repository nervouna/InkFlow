#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
xcrun clang -fobjc-arc -Wall -Wextra -Werror macOS/Tools/RegisterInputSource.m -framework Carbon -framework Foundation -o build/register-input-source
build/register-input-source "${1:-$HOME/Library/Input Methods/InkFlow.app}"
