#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash macOS/scripts/test-release-receipt.sh
bash macOS/scripts/test-release-resume.sh
bash macOS/scripts/test-sparkle-signing.sh
bash macOS/scripts/test-developer-id.sh
bash macOS/scripts/test-install.sh
bash macOS/scripts/test-pkg.sh
bash macOS/scripts/test-dependencies-cache.sh
bash macOS/scripts/test-build-workflow.sh
bash macOS/scripts/test-cleanup.sh
echo 'PASS workflow fixtures: receipt/install signing, Developer ID identities, installer package, dependency cache, staged build and cleanup boundaries'
