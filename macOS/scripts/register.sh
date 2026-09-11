#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p build
source macOS/scripts/swift-package.sh
build_swift_product register-input-source build/register-input-source debug
if [[ $# == 0 ]]; then set -- "$HOME/Library/Input Methods/InkFlow.app"; fi
build/register-input-source "$@"
