#!/bin/bash
# The Developer ID Application and Installer identities are checked the same way, and the release
# configuration requires both. Stand-in security and openssl tools keep the keychain out of it.
set -euo pipefail
cd "$(dirname "$0")/../.."
fixture=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-developer-id-tests.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
mkdir "$fixture/bin"
export APP_ID=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA INSTALLER_ID=BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
cat > "$fixture/bin/security" <<'STUB'
#!/bin/bash
application='Developer ID Application: Fixture (T7976FL2LP)'
installer='Developer ID Installer: Fixture (T7976FL2LP)'
case "$*" in
  'find-identity -v -p codesigning') printf '  1) %s "%s"\n' "$APP_ID" "$application" ;;
  'find-identity -v -p basic') printf '  1) %s "%s"\n  2) %s "%s"\n' "$APP_ID" "$application" "$INSTALLER_ID" "$installer" ;;
  'find-certificate -a -c Developer ID Application -p') printf '%s\n' '-----BEGIN CERTIFICATE-----' application '-----END CERTIFICATE-----' ;;
  'find-certificate -a -c Developer ID Installer -p') printf '%s\n' '-----BEGIN CERTIFICATE-----' installer '-----END CERTIFICATE-----' ;;
  *) exit 99 ;;
esac
STUB
cat > "$fixture/bin/openssl" <<'STUB'
#!/bin/bash
if [[ "$*" == *-fingerprint* ]]; then
  if grep -q installer "$3"; then id=$INSTALLER_ID; else id=$APP_ID; fi
  printf 'sha1 Fingerprint=%s\n' "$(sed 's/../&:/g;s/:$//' <<< "$id")"
else
  printf 'organizationalUnitName = %s\n' "${CERT_TEAM:-T7976FL2LP}"
fi
STUB
chmod +x "$fixture/bin/"*
verify() { PATH="$fixture/bin:$PATH" bash macOS/scripts/verify-developer-id.sh "$@"; }
verify "$APP_ID" T7976FL2LP | grep -Fq 'Developer ID Application'
verify "$APP_ID" T7976FL2LP application >/dev/null
verify "$INSTALLER_ID" T7976FL2LP installer | grep -Fq 'Developer ID Installer'
# Each kind accepts only its own certificate and the right team.
if verify "$INSTALLER_ID" T7976FL2LP >/dev/null 2>&1; then exit 1; fi
if verify "$APP_ID" T7976FL2LP installer >/dev/null 2>&1; then exit 1; fi
if CERT_TEAM=OTHERTEAM1 verify "$INSTALLER_ID" T7976FL2LP installer >/dev/null 2>&1; then exit 1; fi
if verify "$INSTALLER_ID" T7976FL2LP bundle >/dev/null 2>&1; then exit 1; fi

config="$fixture/release.plist"
plutil -create xml1 "$config"
plutil -insert INKFLOW_SIGN_IDENTITY -string "$APP_ID" "$config"
plutil -insert INKFLOW_NOTARY_PROFILE -string fixture-profile "$config"
load() { env -i PATH="$PATH" HOME="$HOME" INKFLOW_RELEASE_CONFIG="$config" bash -c 'source .agents/skills/inkflow-release/scripts/release-config.sh; load_release_config "$@"' load "$@"; }
if load > "$fixture/output" 2>&1; then exit 1; fi
grep -Fq 'INKFLOW_INSTALLER_IDENTITY' "$fixture/output"
plutil -insert INKFLOW_INSTALLER_IDENTITY -string not-a-hash "$config"
if load >/dev/null 2>&1; then exit 1; fi
plutil -replace INKFLOW_INSTALLER_IDENTITY -string "$INSTALLER_ID" "$config"
load >/dev/null
# Standalone notarization checks need no signing identity.
load notary >/dev/null
echo 'PASS Developer ID identities: application and installer certificates verified alike, release config requires both'
