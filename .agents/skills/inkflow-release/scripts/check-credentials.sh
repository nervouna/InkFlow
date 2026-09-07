#!/bin/bash
set -euo pipefail
# shellcheck source=release-config.sh
source "$(dirname "$0")/release-config.sh"
load_release_config
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-credentials.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
identity=$(printf '%s' "$INKFLOW_SIGN_IDENTITY" | tr '[:lower:]' '[:upper:]')
security find-identity -v -p codesigning > "$scratch/identities"
awk -v id="$identity" '$2 == id && /Developer ID Application:/ {found=1} END {exit !found}' "$scratch/identities" || {
  echo 'Configured Developer ID signing identity unavailable. Check Keychain access and certificate validity.' >&2; exit 1;
}
# Export public certificates only, never private keys or Keychain credentials.
security find-certificate -a -c 'Developer ID Application' -p > "$scratch/certificates.pem"
awk -v dir="$scratch" '/-----BEGIN CERTIFICATE-----/ {n++; file=dir "/cert-" n ".pem"} file {print > file} /-----END CERTIFICATE-----/ {close(file); file=""}' "$scratch/certificates.pem"
matched=false
for cert in "$scratch"/cert-*.pem; do
  [[ -f "$cert" ]] || continue
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
  if [[ "$fingerprint" == "$identity" ]]; then
    openssl x509 -in "$cert" -noout -subject -nameopt multiline | awk '
      /organizationalUnitName/ && $NF == "T7976FL2LP" {found=1}
      END {exit !found}' || { echo 'Signing certificate OU does not match the InkFlow team.' >&2; exit 1; }
    matched=true
    break
  fi
done
[[ "$matched" == true ]] || { echo 'Could not verify the selected public certificate.' >&2; exit 1; }
if ! bash "$(dirname "$0")/notary.sh" history --output-format plist >/dev/null 2> "$scratch/notary-error"; then
  echo 'Notarization authentication failed. Check the configured authentication source, network and execution permissions.' >&2
  exit 1
fi
echo 'PASS: Developer ID identity, certificate OU and notarization authentication'
