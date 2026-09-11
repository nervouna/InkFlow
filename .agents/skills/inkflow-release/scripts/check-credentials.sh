#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/../../../.." && pwd)
# shellcheck source=release-config.sh
source "$(dirname "$0")/release-config.sh"
load_release_config
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-credentials.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
bash "$root/macOS/scripts/verify-developer-id.sh" "$INKFLOW_SIGN_IDENTITY" T7976FL2LP
if ! bash "$(dirname "$0")/notary.sh" history --output-format plist >/dev/null 2> "$scratch/notary-error"; then
  echo 'Notarization authentication failed. Check the configured authentication source, network and execution permissions.' >&2
  exit 1
fi
echo 'PASS: Developer ID identity, certificate OU and notarization authentication'
