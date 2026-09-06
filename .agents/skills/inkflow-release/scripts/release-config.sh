#!/bin/bash
# Source this helper, then call load_release_config. The plist is data, not shell code.
load_release_config() {
  local root config
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
  config=${INKFLOW_RELEASE_CONFIG:-$root/.release.local.plist}
  if [[ -e "$config" ]]; then
    plutil -lint "$config" >/dev/null 2>&1 || { echo 'Invalid release configuration plist.' >&2; return 1; }
    if [[ -z ${INKFLOW_SIGN_IDENTITY+x} ]]; then
      INKFLOW_SIGN_IDENTITY=$(plutil -extract INKFLOW_SIGN_IDENTITY raw "$config" 2>/dev/null) || true
    fi
    if [[ -z ${INKFLOW_NOTARY_PROFILE+x} ]]; then
      INKFLOW_NOTARY_PROFILE=$(plutil -extract INKFLOW_NOTARY_PROFILE raw "$config" 2>/dev/null) || true
    fi
  fi
  [[ ${INKFLOW_SIGN_IDENTITY:-} =~ ^[[:xdigit:]]{40}$ ]] || {
    echo 'Set INKFLOW_SIGN_IDENTITY to a Developer ID certificate SHA1 in the environment or .release.local.plist.' >&2; return 1;
  }
  [[ -n ${INKFLOW_NOTARY_PROFILE:-} ]] || {
    echo 'Set INKFLOW_NOTARY_PROFILE to an existing Keychain profile in the environment or .release.local.plist.' >&2; return 1;
  }
  export INKFLOW_SIGN_IDENTITY INKFLOW_NOTARY_PROFILE
}
