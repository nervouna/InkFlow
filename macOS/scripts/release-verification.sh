#!/bin/bash
# Build the clean release candidate once, run the full suite once, deep-check the bundle,
# and freeze the installer executable/icon that packaging consumes.
set -euo pipefail
cd "$(dirname "$0")/../.."

[[ -z $(git status --porcelain --untracked-files=normal) ]] || { echo 'Release verification requires a clean commit.' >&2; exit 1; }
release_commit=$(git rev-parse HEAD)

bash macOS/scripts/build.sh
bash macOS/scripts/test.sh all
bash macOS/scripts/check-bundle.sh --deep

source macOS/scripts/swift-package.sh
receipt_dir=build/release-verification
mkdir -p "$receipt_dir"
build_swift_product InkFlowInstaller "$receipt_dir/InkFlowInstaller" release
cp build/AppIcon.icns "$receipt_dir/AppIcon.icns"
[[ "$(git rev-parse HEAD)" == "$release_commit" && -z $(git status --porcelain --untracked-files=normal) ]] || {
  echo 'Release source changed during verification.' >&2; exit 1;
}
bash macOS/scripts/release-receipt.sh create "$receipt_dir/InkFlowInstaller" "$receipt_dir/AppIcon.icns" "$receipt_dir/installer.plist"
echo 'PASS release verification'
