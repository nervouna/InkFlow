#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/test-release-verification.sh
bash macOS/scripts/test-release-receipt.sh
bash macOS/scripts/test-dependencies-cache.sh
bash macOS/scripts/test-build-workflow.sh
bash macOS/scripts/test-cleanup.sh
echo 'PASS workflow fixtures: release matrix, dependency cache, staged build and cleanup boundaries'
