#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
source macOS/scripts/swift-package.sh
build_swift_product InkFlowInstaller build/installer-core/InkFlowInstaller debug
build_swift_product register-input-source build/installer-core/register-input-source debug
printf 'PASS production installer core and register CLI compile (not executed)\n'
