#!/bin/bash
set +x
set -euo pipefail
# shellcheck source=release-config.sh
source "$(dirname "$0")/release-config.sh"
load_release_config notary
case "${1:-}" in
  submit|info|log|history) ;;
  *) echo 'Usage: notary.sh submit|info|log|history [arguments]' >&2; exit 2 ;;
esac
for argument in "$@"; do
  case "$argument" in
    --key*|--issuer*|--password*|--apple-id*|--team-id*|-k*|-d*|-i*|-p*)
      echo 'Configure notarization authentication in .release.local.plist or environment, not command arguments.' >&2; exit 2 ;;
  esac
done
if [[ ${INKFLOW_NOTARY_AUTH:-keychain} == api-key ]]; then
  auth=(--key "$INKFLOW_NOTARY_KEY_FILE" --key-id "$INKFLOW_NOTARY_KEY_ID")
  # Team keys require an issuer; individual keys must omit it.
  if [[ -n ${INKFLOW_NOTARY_ISSUER:-} ]]; then auth+=(--issuer "$INKFLOW_NOTARY_ISSUER"); fi
else
  auth=(--keychain-profile "$INKFLOW_NOTARY_PROFILE")
fi
exec xcrun notarytool "$@" "${auth[@]}" </dev/null
