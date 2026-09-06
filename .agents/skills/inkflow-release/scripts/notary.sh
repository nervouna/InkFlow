#!/bin/bash
set -euo pipefail
# shellcheck source=release-config.sh
source "$(dirname "$0")/release-config.sh"
load_release_config
case "${1:-}" in
  submit|info|log|history) ;;
  *) echo 'Usage: notary.sh submit|info|log|history [arguments]' >&2; exit 2 ;;
esac
exec xcrun notarytool "$@" --keychain-profile "$INKFLOW_NOTARY_PROFILE"
