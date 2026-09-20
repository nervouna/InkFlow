#!/bin/bash
# Read the completed artifact; this report never allocates or changes its identity.
set -euo pipefail
[[ $# == 1 ]] || { echo 'Usage: build-summary.sh APP' >&2; exit 2; }
app=$1
info="$app/Contents/Info.plist"
quality="$app/Contents/Resources/QualityBuild.json"
row() {
  local value=$2
  value=${value//|/\\|}
  value=${value//$'\n'/ }
  printf '| %s | %s |\n' "$1" "$value"
}
printf '\n| Artifact metadata | Value |\n| --- | --- |\n'
row Path "$app"
row Version "$(plutil -extract CFBundleShortVersionString raw "$info")"
row Build "$(plutil -extract CFBundleVersion raw "$info")"
row 'Bundle ID' "$(plutil -extract CFBundleIdentifier raw "$info")"
row 'Source commit' "$(plutil -extract sourceRevision raw "$quality")"
row 'Source dirty' "$(plutil -extract sourceDirty raw "$quality")"
row 'Source SHA-256' "$(plutil -extract sourceTreeSHA256 raw "$quality")"
row 'Bundle SHA-256 (build metadata)' "$(plutil -extract bundleSHA256 raw "$quality")"
row 'Executable SHA-256' "$(shasum -a 256 "$app/Contents/MacOS/InkFlow" | awk '{print $1}')"
row 'Reported (UTC)' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
signature=$(codesign -dvvv "$app" 2>&1 || true)
team=$(printf '%s\n' "$signature" | sed -n 's/^TeamIdentifier=//p')
authority=$(printf '%s\n' "$signature" | sed -n 's/^Authority=//p' | head -1)
if codesign --verify --deep --strict "$app" >/dev/null 2>&1; then
  row 'Signature integrity' verified
else
  row 'Signature integrity' 'not verified (unsigned or invalid)'
fi
row 'Signing authority' "${authority:-none (unsigned or ad-hoc)}"
row 'Signing team' "${team:-none}"
row 'Installation / notarization' 'Not checked by this report'
