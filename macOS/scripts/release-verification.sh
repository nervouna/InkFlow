#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

[[ -z $(git status --porcelain --untracked-files=normal) ]] || { echo 'Release verification requires a clean commit.' >&2; exit 1; }
release_commit=$(git rev-parse HEAD)

bash macOS/scripts/build.sh
bash macOS/scripts/test.sh all
bash macOS/scripts/check-bundle.sh --deep

[[ "$(git rev-parse HEAD)" == "$release_commit" && -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Release source changed during verification.' >&2; exit 1;
}
bash macOS/scripts/release-receipt.sh create build/release-verification/receipt.plist
echo 'PASS release verification'
