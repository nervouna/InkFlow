#!/bin/bash
set -euo pipefail
[[ $# -eq 2 ]] || { echo 'Usage: verify-developer-id.sh CERTIFICATE_SHA1 TEAM_ID' >&2; exit 2; }
identity=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
team=$2
[[ "$identity" =~ ^[[:xdigit:]]{40}$ && -n "$team" ]] || { echo 'Invalid Developer ID identity or team.' >&2; exit 2; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/inkflow-developer-id.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

security find-identity -v -p codesigning > "$scratch/identities"
awk -v id="$identity" '$2 == id && /Developer ID Application:/ {found=1} END {exit !found}' "$scratch/identities" || {
  echo 'Selected identity is not an available valid Developer ID Application certificate.' >&2; exit 1;
}

# Export public certificates only; private keys and Keychain credentials never leave Keychain.
security find-certificate -a -c 'Developer ID Application' -p > "$scratch/certificates.pem"
awk -v dir="$scratch" '/-----BEGIN CERTIFICATE-----/ {n++; file=dir "/cert-" n ".pem"} file {print > file} /-----END CERTIFICATE-----/ {close(file); file=""}' "$scratch/certificates.pem"
matched=false
for cert in "$scratch"/cert-*.pem; do
  [[ -f "$cert" ]] || continue
  fingerprint=$(openssl x509 -in "$cert" -noout -fingerprint -sha1 | cut -d= -f2 | tr -d ':')
  if [[ "$fingerprint" == "$identity" ]]; then
    openssl x509 -in "$cert" -noout -subject -nameopt multiline | awk -v team="$team" '
      /organizationalUnitName/ && $NF == team {found=1}
      END {exit !found}' || { echo 'Signing certificate OU does not match the InkFlow team.' >&2; exit 1; }
    matched=true
    break
  fi
done
[[ "$matched" == true ]] || { echo 'Could not verify the selected Developer ID public certificate.' >&2; exit 1; }
echo 'PASS: valid Developer ID Application identity and certificate team'
