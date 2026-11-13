#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
# The release workflow exports its real configuration before verification. The fixtures start from a developer
# Mac's environment and set what each case tests; the release configuration lets the environment win.
unset INKFLOW_RELEASE_CONFIG INKFLOW_SIGN_IDENTITY INKFLOW_INSTALLER_IDENTITY INKFLOW_NOTARY_PROFILE
unset INKFLOW_NOTARY_AUTH INKFLOW_NOTARY_KEY_FILE INKFLOW_NOTARY_KEY_ID INKFLOW_NOTARY_KEY_TYPE
unset INKFLOW_NOTARY_ISSUER INKFLOW_SPARKLE_KEY_FILE
bash macOS/scripts/test-release-receipt.sh
bash macOS/scripts/test-release-resume.sh
bash macOS/scripts/test-sparkle-signing.sh
bash macOS/scripts/test-developer-id.sh
bash macOS/scripts/test-install.sh
bash macOS/scripts/test-pkg.sh
bash macOS/scripts/test-build-workflow.sh
bash macOS/scripts/test-cleanup.sh
echo 'PASS workflow fixtures: receipt/install signing, Developer ID identities, installer package, staged build and cleanup boundaries'
