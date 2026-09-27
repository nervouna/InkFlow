#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/test-release-verification.sh
bash macOS/scripts/test-release-receipt.sh
bash macOS/scripts/test-sparkle-signing.sh
bash macOS/scripts/test-install.sh
bash macOS/scripts/test-dependencies-cache.sh
bash macOS/scripts/test-build-workflow.sh
bash macOS/scripts/test-cleanup.sh
bash macOS/scripts/test-core-coverage.sh
bash macOS/scripts/test-bundle-artifact-smoke.sh
echo 'PASS workflow fixtures: release matrix, receipt/install signing, dependency cache, staged build, coverage ownership, bundle smoke and cleanup boundaries'
