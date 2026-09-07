#!/bin/bash
# Source this helper, then call load_release_config. The plist is data, not shell code.
load_release_config() {
  local root config name permissions
  root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
  config=${INKFLOW_RELEASE_CONFIG:-$root/.release.local.plist}
  if [[ -e "$config" ]]; then
    plutil -lint "$config" >/dev/null 2>&1 || { echo 'Invalid release configuration plist.' >&2; return 1; }
    for name in INKFLOW_SIGN_IDENTITY INKFLOW_NOTARY_PROFILE INKFLOW_NOTARY_AUTH INKFLOW_NOTARY_KEY_FILE INKFLOW_NOTARY_KEY_ID INKFLOW_NOTARY_KEY_TYPE INKFLOW_NOTARY_ISSUER; do
      if [[ -z ${!name+x} ]]; then
        printf -v "$name" '%s' "$(plutil -extract "$name" raw "$config" 2>/dev/null || true)"
      fi
    done
  fi
  if [[ ${1:-} != notary ]]; then
    [[ ${INKFLOW_SIGN_IDENTITY:-} =~ ^[[:xdigit:]]{40}$ ]] || {
    echo 'Set INKFLOW_SIGN_IDENTITY to a Developer ID certificate SHA1 in the environment or .release.local.plist.' >&2; return 1;
    }
  fi
  case ${INKFLOW_NOTARY_AUTH:-keychain} in
  keychain)
    [[ -n ${INKFLOW_NOTARY_PROFILE:-} ]] || {
    echo 'Set INKFLOW_NOTARY_PROFILE to an existing Keychain profile in the environment or .release.local.plist.' >&2; return 1;
    }
    ;;
  api-key)
    [[ -n ${INKFLOW_NOTARY_KEY_FILE:-} && -n ${INKFLOW_NOTARY_KEY_ID:-} ]] || { echo 'API key mode requires INKFLOW_NOTARY_KEY_FILE and INKFLOW_NOTARY_KEY_ID.' >&2; return 1; }
    case ${INKFLOW_NOTARY_KEY_TYPE:-team} in
      team) [[ -n ${INKFLOW_NOTARY_ISSUER:-} ]] || { echo 'Team API key requires INKFLOW_NOTARY_ISSUER.' >&2; return 1; } ;;
      individual) [[ -z ${INKFLOW_NOTARY_ISSUER:-} ]] || { echo 'Individual API key must not specify an issuer.' >&2; return 1; } ;;
      *) echo 'INKFLOW_NOTARY_KEY_TYPE must be team or individual.' >&2; return 1 ;;
    esac
    if [[ "$INKFLOW_NOTARY_KEY_FILE" != /* ]]; then
      INKFLOW_NOTARY_KEY_FILE="$(dirname "$config")/$INKFLOW_NOTARY_KEY_FILE"
    fi
    [[ -f "$INKFLOW_NOTARY_KEY_FILE" && -r "$INKFLOW_NOTARY_KEY_FILE" ]] || { echo 'Notarization API key file is missing or unreadable.' >&2; return 1; }
    permissions=$(stat -f %Lp "$INKFLOW_NOTARY_KEY_FILE") || return 1
    (( (8#$permissions & 077) == 0 )) || { echo 'Restrict the API key file to owner-only access (chmod 600).' >&2; return 1; }
    ;;
  *) echo 'INKFLOW_NOTARY_AUTH must be keychain or api-key.' >&2; return 1 ;;
  esac
  export INKFLOW_SIGN_IDENTITY INKFLOW_NOTARY_PROFILE INKFLOW_NOTARY_AUTH INKFLOW_NOTARY_KEY_FILE INKFLOW_NOTARY_KEY_ID INKFLOW_NOTARY_KEY_TYPE INKFLOW_NOTARY_ISSUER
}
